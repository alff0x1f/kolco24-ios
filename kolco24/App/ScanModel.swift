//
//  ScanModel.swift
//  kolco24
//
//  `@Observable @MainActor`-хост-редьюсер скан-оверлея «Отметить КП». Порт ПОВЕДЕНИЯ (не структуры)
//  трёх мест Android: `MainActivity.onScanTag`-редьюсера (~1329–1468), `ScanTakeState` (~475–483) и
//  таймер/фанфары/автозакрытия из `ui/scan/ScanScreen.kt`. В Android это размазано по 2220-строчному
//  composable + отдельному экрану; на iOS собрано в одну `@Observable`-модель поверх РЕАЛЬНЫХ сторов.
//
//  Два зеркальных состояния (Technical Details §1): чистая `ScanSession` (UI: КП, present, окно) и
//  take-state для БД (`markId`/`checkpointId`/`expectedCount`/`buffer`/`present`/`snapshots`/`lastScanAt`).
//  Окно считается по монотонному `TagReading.sample.elapsedMs` (§8 — семпл берёт сканер ДО чтения чипа).
//
//  Единый FIFO-стрим (`ScanInput`: чтение чипа / тик окна / пере-проверка автозакрытия) сериализует
//  обработку (§7 — замена Android-`scanMutex`): и истечение окна, и completion-hold проходят ТЕМ ЖЕ
//  потоком, что и чтения, поэтому near-deadline чтение, поднятое до тика, всегда применяется ПЕРЕД
//  оценкой истечения (буферизованное-но-ещё-не-снятое чтение не финализируется как истёкшее).
//  Записи в БД — в НЕструктурированных `Task`, захватывающих сторы (а не `self`): закрытие оверлея
//  не обрывает начатый `upsert`/`addMember`/`attachLocation` (§6 — аналог `applicationScope`).
//
//  Сканер — через шов `any ChipScanning` (`start(scanner:)`): тесты передают `FakeChipScanner`, прод
//  `NfcChipScanner` подключится в задаче 8. `import SwiftUI`/`GRDB`/`CoreNFC` запрещены (grep-инвариант)
//  — хватает `Observation`/`Foundation`; модель зависит только от протоколов `Core/` и сторов.
//

import Foundation
import Observation

@MainActor
@Observable
final class ScanModel: Identifiable {

    /// Стабильный id для `.sheet(item:)` в `MarksView` (один оверлей = одна модель).
    nonisolated let id = UUID()

    // MARK: - UI-состояние (observable)

    /// Чистая UI-сессия окна (КП, present, buffered, `lastScanAt`) — драйвит грид слотов и таймер.
    /// `nil` до первого принятого скана и после финализации.
    private(set) var session: ScanSession?
    /// Остаток окна в мс (тик 250 мс). Полное окно, пока сессии нет.
    private(set) var remainingMillis: Int64 = SCAN_WINDOW_MS
    /// Диагностика последнего тапа (`badKp`/`unboundChip`) для строки под таймером; `nil` — успех.
    private(set) var diagnostic: String?
    /// «Готово!»-бит: КП идентифицирован + весь ростер present; держится `SUCCESS_HOLD_MS`, затем автозакрытие.
    private(set) var completed = false
    /// Сигнал автозакрытия оверлея (истечение окна / завершение / конец стрима). Вьюха его наблюдает.
    private(set) var closeRequested = false
    /// `true`, если оверлей закрылся по УСПЕШНОМУ завершению взятия (весь ростер present), а не по истечению
    /// окна/концу стрима. Выставляется в `handleCompletionCheck()` перед `finalizeSession()`; читается ПОСЛЕ
    /// dismiss (`MarksView` запускает конфетти) — истечение окна его НЕ выставляет.
    private(set) var didComplete = false

    /// Потокобезопасное зеркало «оверлей жив» для `NfcChipScanner.shouldRestart` (читается на делегатной
    /// NFC-очереди, пишется здесь на MainActor). `true` с момента создания (оверлей открыт) → `false` на
    /// любом `closeRequested`. Заменяет прямое чтение @MainActor `closeRequested` с чужой очереди (гонка).
    @ObservationIgnored let liveness = ScanLiveness(alive: true)

    /// Остаток окна в секундах (для кольца таймера).
    var remainingSeconds: Double { Double(remainingMillis) / 1000 }

    // MARK: - Derived для вьюхи (читают observable `session`/`roster` → трекаются SwiftUI)

    /// «Готово» активна, когда КП идентифицирован (порт `canFinish = session?.checkpointId != nil`).
    var canFinish: Bool { session?.checkpointId != nil }
    /// Номер идентифицированного КП (после `.kp`); `nil` — ждём чип КП.
    var checkpointNumber: Int? { session?.checkpointNumber }
    /// Цена идентифицированного КП; `nil` — ждём чип КП.
    var checkpointCost: Int? { session?.cost }
    /// Слоты ростера, уже отсканированные (present + буфер до КП) — драйвит галочки грида.
    var scannedSlots: Set<Int> {
        (session?.present ?? []).union(session?.bufferedBeforeKp ?? [])
    }
    /// Сколько чипов ещё ждём (`roster − scanned`, порт `remaining`).
    var remainingScans: Int { max(0, roster.count - scannedSlots.count) }

    // MARK: - Наблюдаемые привязки (для classifyTag)

    /// `uid → numberInTeam` привязок текущей команды, отфильтрованных по слотам ростера (§2). Стейл-чип
    /// удалённого участника читается как `unboundChip`, а не подменяет реального.
    private(set) var bindings: [String: Int] = [:]
    /// `numberInTeam → participantNumber` (глобальный номер) — для снимка present-участника при загрузке.
    private(set) var chipNumbers: [Int: Int] = [:]

    // MARK: - Take-state для БД (не-observable, §1)

    @ObservationIgnored private var markId: String?
    @ObservationIgnored private var takeCheckpointId: Int?
    @ObservationIgnored private var expectedCount = 0
    @ObservationIgnored private var buffer = Set<Int>()
    @ObservationIgnored private var takePresent = Set<Int>()
    @ObservationIgnored private var snapshots = [Int: MarkMemberSnapshot]()
    /// Монотонный `elapsedMs` последнего ПРИНЯТОГО скана — источник `isWindowExpired` (§1). `nil` — не было.
    @ObservationIgnored private var takeLastScanAt: Int64?

    // MARK: - Зависимости (граф — через AppModel.makeScanModel)

    @ObservationIgnored let raceId: Int
    @ObservationIgnored let teamId: Int
    @ObservationIgnored let roster: [TeamMemberItem]
    @ObservationIgnored private let rosterSlots: Set<Int>
    @ObservationIgnored private let legendRepository: LegendRepository
    @ObservationIgnored private let markStore: MarkStore
    @ObservationIgnored private let bindingStore: MemberChipBindingStore
    @ObservationIgnored private let locationProvider: any CurrentLocationProvider
    @ObservationIgnored private let feedback: any ScanFeedbackPlaying
    /// Текущий монотонный `elapsedMs` (для таймера окна) — инжектируется (`trustedClock.sample().elapsedMs`
    /// в проде; управляемое время в тестах).
    @ObservationIgnored private let elapsedNowMs: @Sendable () async -> Int64
    /// Генератор id взятия (UUID в проде; детерминированный в тестах).
    @ObservationIgnored private let newMarkId: () -> String

    // MARK: - Тюнинг таймингов (тестируемое время)

    @ObservationIgnored private let tickMs: Int64
    @ObservationIgnored private let fanfareDelayMs: Int64
    @ObservationIgnored private let successHoldMs: Int64

    // MARK: - Задачи

    /// Активный сканер: фабрика `AppModel.makeScanModel()` (задача 8) привязывает прод `NfcChipScanner`
    /// через `attachProductionScanner`, вьюха стартует его без-аргументным `beginScanning()` (оставаясь
    /// `CoreNFC`-free); тесты подают `FakeChipScanner` прямо в `start(scanner:)`.
    @ObservationIgnored private var scanner: (any ChipScanning)?
    /// Единый сериализованный вход: чтения чипов, тики окна и пере-проверки автозакрытия сходятся в один
    /// FIFO-стрим (§7 — замена Android-`scanMutex`). Так решение об истечении окна и completion-hold
    /// принимаются в порядке FIFO ПОСЛЕ всех чтений, поднятых раньше события (Finding-1).
    private enum ScanInput: Sendable {
        case reading(TagReading)
        case tick
        case completionCheck
    }
    /// Континуейшн общего стрима: таймер кладёт `.tick`, completion-hold — `.completionCheck`, форвардер
    /// чтений — `.reading`. Потребитель (`streamTask`) снимает их последовательно.
    @ObservationIgnored private var inputContinuation: AsyncStream<ScanInput>.Continuation?
    /// Форвардит `scanner.readings()` в общий стрим; на конце потока закрывает общий стрим.
    @ObservationIgnored private var forwardTask: Task<Void, Never>?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var bindingsTask: Task<Void, Never>?
    @ObservationIgnored private var completionTask: Task<Void, Never>?
    @ObservationIgnored private var fanfareTask: Task<Void, Never>?
    /// Задача персиста строки текущего взятия (`upsert`). Последующие `addMember`/`attachLocation`
    /// ждут её `.value`, чтобы строка гарантированно существовала до их записи (см. §6-порядок ниже).
    /// НЕ отменяется на `stop()`/`deinit` — запись должна пережить закрытие оверлея (§6).
    @ObservationIgnored private var takePersistTask: Task<Void, Never>?

    /// `TIMER_TICK_MS` из `ScanScreen.kt`.
    private static let defaultTickMs: Int64 = 250
    /// `COMPLETE_FANFARE_DELAY_MS` из `ScanScreen.kt`.
    private static let defaultFanfareDelayMs: Int64 = 275
    /// Быстрое автозакрытие (этап 11): удержание «Готово!»-бита убрано — оверлей закрывается немедленно,
    /// «Готово!» остаётся видимым лишь на время анимации закрытия шита, конфетти играет на «Отметках».
    /// Механизм холда (FIFO-пере-проверка `completionCheck`, Finding-1) не тронут — просто нулевая задержка.
    private static let defaultSuccessHoldMs: Int64 = 0

    init(
        raceId: Int,
        teamId: Int,
        roster: [TeamMemberItem],
        legendRepository: LegendRepository,
        markStore: MarkStore,
        bindingStore: MemberChipBindingStore,
        locationProvider: any CurrentLocationProvider,
        feedback: any ScanFeedbackPlaying,
        elapsedNowMs: @escaping @Sendable () async -> Int64,
        newMarkId: @escaping () -> String = { UUID().uuidString },
        tickMs: Int64 = ScanModel.defaultTickMs,
        fanfareDelayMs: Int64 = ScanModel.defaultFanfareDelayMs,
        successHoldMs: Int64 = ScanModel.defaultSuccessHoldMs
    ) {
        self.raceId = raceId
        self.teamId = teamId
        self.roster = roster
        self.rosterSlots = Set(roster.map { $0.numberInTeam })
        self.legendRepository = legendRepository
        self.markStore = markStore
        self.bindingStore = bindingStore
        self.locationProvider = locationProvider
        self.feedback = feedback
        self.elapsedNowMs = elapsedNowMs
        self.newMarkId = newMarkId
        self.tickMs = tickMs
        self.fanfareDelayMs = fanfareDelayMs
        self.successHoldMs = successHoldMs
        startBindingsObservation()
    }

    deinit {
        // Зеркалит синхронную часть `stop()` для deinit-only-пути (dealloc без предшествующего `stop()`):
        // гасим liveness, финишируем общий стрим и останавливаем сканер, не полагаясь на случайный порядок
        // релиза. deinit на @MainActor-классе nonisolated — только СИНХРОННЫЕ операции над уже-`Sendable`
        // членами (Task.cancel / Continuation.finish / ScanLiveness.set / scanner.stop), без `await` и без
        // воскрешения `self` в escaping-замыкании. `streamTask` здесь отменяем (self уничтожается —
        // дренировать некому); `takePersistTask` намеренно НЕ трогаем — запись должна пережить закрытие (§6).
        liveness.set(false)
        forwardTask?.cancel()
        streamTask?.cancel()
        timerTask?.cancel()
        bindingsTask?.cancel()
        completionTask?.cancel()
        fanfareTask?.cancel()
        inputContinuation?.finish()
        scanner?.stop()
    }

    // MARK: - Жизненный цикл сканирования

    /// Открывает сессию сканирования: стартует сканер, единственный `for await` по его стриму и таймер
    /// окна. Конец стрима (отмена пользователем / NFC недоступен) → `closeRequested`.
    func start(scanner: any ChipScanning) {
        self.scanner = scanner
        // `readings()` ДО `start()`: прод-сканер синхронно завершает поток прямо в `start()`, когда NFC
        // недоступен (`beginSession`→`finishStream`); установи мы континуейшн после — он бы висел на уже
        // «мёртвом» потоке и `closeRequested` никогда бы не выставился (оверлей не автозакрылся).
        let readings = scanner.readings()
        scanner.start()

        // Единый FIFO-вход (§7 — замена Android-`scanMutex`): чтения, тики окна и completion-check
        // сходятся в ОДИН стрим, потребитель снимает их строго последовательно. Чтение, попавшее в
        // общий стрим раньше тика, всегда обрабатывается перед оценкой истечения (буферизованное-но-
        // ещё-не-снятое чтение не финализируется как истёкшее из-под нас).
        let (inputs, continuation) = AsyncStream.makeStream(of: ScanInput.self)
        inputContinuation = continuation

        // Форвардер: чтения сканера → общий стрим; конец потока (отмена / недоступность NFC) закрывает
        // общий стрим → потребитель зовёт `requestClose`.
        //
        // Finding-1 (остаточная гонка эмиссии — ОСОЗНАННАЯ, безобидная). Чтения приходят с одним лишним
        // хопом (сканерский `readings()` → форвардер → общий стрим), тогда как `.tick`/`.completionCheck`
        // кладутся в общий стрим напрямую. Два независимо планируемых async-источника нельзя упорядочить
        // идеально без общей точки сериализации НА ЭМИССИИ, а `AsyncStream.Iterator` не `Sendable` —
        // безопасного read-with-timeout в одной задаче (слить чтения и тики в одного продюсера) на голом
        // `AsyncStream` (без swift-async-algorithms) нет. Поэтому у самой 20-с границы, в пределах
        // джиттера планировщика, тик может опередить чтение, поднятое чуть раньше по wall-time.
        // Последствие безобидно и НЕ теряет данные: (1) чтение несёт СВОЙ монотонный `sample.elapsedMs`
        // (§8), поэтому даже снятое ПОСЛЕ тика near-deadline чтение продлевает взятие по собственному
        // времени; (2) истечение сбрасывает только UI-`session`, а не take-state — `addMember` всё равно
        // персистит участника (§6); (3) `stop()` НЕ обрывает потребителя резко, а даёт ему дренировать
        // уже форварднутые чтения (см. `stop()`), поэтому принятый скан не пропадает между `requestClose`
        // и teardown. Худший исход — оверлей закрывается на доли джиттера «рано» ровно на 20-с границе,
        // БД при этом корректна. Усложнять ради идеальной гарантии здесь не оправдано.
        forwardTask = Task {
            for await reading in readings { continuation.yield(.reading(reading)) }
            continuation.finish()
        }

        streamTask = Task { [weak self] in
            for await input in inputs {
                guard let self else { return }
                switch input {
                case let .reading(reading): await self.process(reading)
                case .tick: await self.handleExpiryTick()
                case .completionCheck: self.handleCompletionCheck()
                }
            }
            self?.requestClose()
        }

        // Таймер только КЛАДЁТ тик в общий стрим — само решение об истечении принимает потребитель в
        // порядке FIFO после всех чтений, поднятых раньше тика.
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let tick = self?.tickMs else { return }
                try? await Task.sleep(for: .milliseconds(Int(tick)))
                if Task.isCancelled { return }
                self?.inputContinuation?.yield(.tick)
            }
        }
    }

    /// Идемпотентно инвалидирует сессию (закрытие оверлея). НЕ обрывает уже запущенные записи в БД —
    /// они живут в отдельных `Task`, захвативших сторы.
    func stop() {
        liveness.set(false)
        forwardTask?.cancel()
        timerTask?.cancel()
        completionTask?.cancel()
        fanfareTask?.cancel()
        // `streamTask` НЕ отменяем: `finish()` даёт ему дренировать уже форварднутые (в т.ч. near-deadline,
        // Finding-1) чтения из буфера общего стрима и лишь потом завершиться — принятый скан не пропадёт
        // между `requestClose` и teardown (§6). Он `[weak self]`: снимает оставшиеся входы, зовёт
        // `requestClose` (идемпотентно) и выходит; форвардер уже отменён, новых чтений не будет.
        inputContinuation?.finish()
        scanner?.stop()
    }

    /// Единая точка автозакрытия: выставляет `closeRequested` (вьюха наблюдает) и гасит `liveness`, чтобы
    /// сканер на 60-с таймауте больше не пересоздавал сессию поверх закрывающегося оверлея.
    private func requestClose() {
        closeRequested = true
        liveness.set(false)
    }

    /// Привязать прод-сканер (`AppModel.makeScanModel()`); вьюха стартует его `beginScanning()`.
    func attachProductionScanner(_ scanner: any ChipScanning) {
        self.scanner = scanner
    }

    /// Старт привязанного прод-сканера (вьюха, `.task`). No-op, если сканер не привязан (превью/тесты
    /// стартуют через `start(scanner:)`).
    func beginScanning() {
        guard let scanner else { return }
        start(scanner: scanner)
    }

    /// Запросить разрешение на геолокацию заранее, при первом открытии оверлея (§GPS). Идемпотентно
    /// на уровне ОС (после решения пользователя повторный вызов игнорируется), поэтому дедуп не нужен.
    func requestGeoPermission() {
        locationProvider.requestWhenInUseAuthorization()
    }

    // MARK: - Наблюдение привязок (§2)

    private func startBindingsObservation() {
        let observation = bindingStore.observeForTeam(teamId)
        let slots = rosterSlots
        bindingsTask = Task { [weak self] in
            do {
                for try await rows in observation {
                    guard let self, !Task.isCancelled else { return }
                    let scoped = rows.filter { slots.contains($0.numberInTeam) }
                    self.bindings = Dictionary(
                        scoped.map { ($0.nfcUid, $0.numberInTeam) }, uniquingKeysWith: { first, _ in first }
                    )
                    self.chipNumbers = Dictionary(
                        scoped.map { ($0.numberInTeam, $0.participantNumber) }, uniquingKeysWith: { first, _ in first }
                    )
                }
            } catch {}
        }
    }

    // MARK: - Обработка одного чтения (§2–§5)

    /// Порт `onScanTag` + `process`: одно `TagReading` → unlock → `classifyTag` → take-bookkeeping в БД
    /// → session-reduce + фидбек. Всё сериализовано единым `for await` (§7).
    func process(_ reading: TagReading) async {
        // Сериализовано единым FIFO-стримом (§7): пока идёт process, тик окна / completion-check не могут
        // вклиниться — они снимаются потребителем ПОСЛЕ завершения этого вызова (Finding-1).
        let now = reading.sample.elapsedMs

        // Гвард «команда не выбрана» (§2): пустой ростер — нечего зачитывать, открывать взятие с
        // expectedCount = 0 нельзя (оно никогда не завершится и осиротит строку).
        guard !roster.isEmpty else {
            applyFeedback(.badKp(reason: "команда не выбрана"), now: now)
            return
        }

        let code = reading.code
        let uid = reading.uid
        // unlock — suspend DAO+crypto путь (только для чипа КП).
        let unlock: UnlockOutcome? = code != nil
            ? (try? await legendRepository.unlock(raceId: raceId, code: code!))
            : nil
        // Для Revealed/IdentityOnly перечитываем свежий снимок легенды (наблюдения КП модель не держит,
        // на холодном старте `cost` есть только в снимке DAO). Иначе карта не читается classifyTag'ом.
        let checkpointsById = await checkpointsMap(for: unlock)
        let event = classifyTag(
            code: code, uid: uid, unlock: unlock, bindings: bindings, checkpointsById: checkpointsById
        )

        let expired = isWindowExpired(lastScanAt: takeLastScanAt, now: now)

        switch event {
        case let .kp(checkpointId, number, cost, cpUid, cpCode):
            // Новый КП / истёкшее окно / смена КП → свежее взятие; повтор того же КП при живом окне —
            // только перештамп окна (§3).
            if expired || markId == nil || takeCheckpointId != checkpointId {
                // Истёкшее окно: буфер принадлежит мёртвой сессии — сбрасываем, чтобы стейл-участники
                // не кредитовались новому взятию.
                if expired {
                    buffer.removeAll()
                    snapshots.removeAll()
                }
                let buffered = buffer
                let rosterSize = roster.count
                // Дренаж снимка каждого буферизованного участника; фолбэк на слот-only, чтобы present[]
                // не терял участника.
                let bufferedMembers = buffered.map { slot in
                    snapshots[slot] ?? MarkMemberSnapshot(numberInTeam: slot, nfcUid: nil, number: 0)
                }
                let id = newMarkId()
                let mark = makeKpTakeMark(
                    id: id, raceId: raceId, teamId: teamId, checkpointId: checkpointId,
                    number: number, cost: cost, cpUid: cpUid, cpCode: cpCode,
                    buffered: bufferedMembers, expectedCount: rosterSize, sample: reading.sample
                )
                // Персист в неструктурированном Task, захватившем стор (переживает закрытие оверлея, §6).
                // Ссылку держим в `takePersistTask`: последующие `addMember` в этом же взятии ждут её
                // `.value` ПЕРЕД своей записью. Порт Android `startKpTake(...).await()` (MainActivity.kt
                // ~1381–1404: `scanTake.markId` выставляется лишь ПОСЛЕ того, как строка записана). Без
                // этого `addMember` может опередить `upsert` на серийной очереди writer'а, наткнуться на
                // отсутствующую строку (MarkStore ~119 — no-op на missing row) и молча потерять участника.
                let store = markStore
                let persist = Task { () -> Void in try? await store.upsert(mark) }
                takePersistTask = persist
                markId = id
                // Анти-фрод: один свежий GPS-фикс на ЭТО новое взятие (не перештамп, не addMember).
                // Fire-and-forget — медленный GPS не блокирует окно; nil-фикс = no-op.
                attachLocationForNewTake(markId: id, persist: persist)
                takeCheckpointId = checkpointId
                expectedCount = rosterSize
                // Снимки уже потреблены `bufferedMembers`; чистим, чтобы стейл не копился между сменами КП.
                snapshots.removeAll()
                takePresent = buffered
                buffer.removeAll()
            }
            takeLastScanAt = now

        case let .member(numberInTeam):
            // Участник после мёртвого окна открывает свежую сессию — полный сброс take-state ДО
            // буферизации, чтобы он не кредитовался старому взятию (§4).
            if expired {
                markId = nil
                takeCheckpointId = nil
                buffer.removeAll()
                takePresent.removeAll()
                snapshots.removeAll()
            }
            // Снимок браслета для present[]-загрузки строится ДО проверок идемпотентности (повтор просто
            // перезаписывает то же значение) — так снимок буферизованного участника готов к приходу чипа КП.
            let snapshot = MarkMemberSnapshot(
                numberInTeam: numberInTeam, nfcUid: uid, number: chipNumbers[numberInTeam] ?? 0
            )
            snapshots[numberInTeam] = snapshot
            if let markId, takeCheckpointId != nil {
                // Повтор уже учтённого участника идемпотентен и НЕ перештамповывает окно (иначе один
                // человек мог бы держать взятие живым в одиночку).
                if takePresent.contains(numberInTeam) {
                    applyFeedback(event, now: now)
                    return
                }
                takePresent.insert(numberInTeam)
                let store = markStore
                let expected = expectedCount
                let wall = reading.sample.wallMs
                // Ждём `.value` персиста строки взятия перед записью участника: `addMember` — no-op на
                // отсутствующей строке (MarkStore ~119), поэтому без этого гейта участник может молча
                // выпасть, если его Task опередит `upsert` на серийной очереди writer'а (§6-порядок).
                let persist = takePersistTask
                Task {
                    await persist?.value
                    try? await store.addMember(
                        id: markId, numberInTeam: numberInTeam, nfcUid: uid,
                        number: snapshot.number, code: nil, now: wall, expectedCount: expected
                    )
                }
            } else {
                // Ещё нет КП: держим участника в буфере. Повтор уже буферизованного — идемпотентен, окно
                // не трогаем.
                if buffer.contains(numberInTeam) {
                    applyFeedback(event, now: now)
                    return
                }
                buffer.insert(numberInTeam)
            }
            takeLastScanAt = now

        case .unboundChip, .badKp:
            // Диагностика никогда не открывает взятие и не двигает окно (§5).
            break
        }

        applyFeedback(event, now: now)
    }

    /// Свежий снимок легенды в карту `id → Checkpoint` для `classifyTag`, только когда unlock раскрыл КП.
    private func checkpointsMap(for unlock: UnlockOutcome?) async -> [Int: Checkpoint] {
        switch unlock {
        case .revealed, .identityOnly:
            let snapshot = (try? await legendRepository.checkpointsSnapshot(raceId)) ?? []
            return Dictionary(snapshot.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        default:
            return [:]
        }
    }

    // MARK: - Session-reduce + фидбек (порт `process` из ScanScreen)

    /// Свёртка события в UI-сессию + аудио/тактильный фидбек. `kp`/`member` двигают сессию; `badKp`/
    /// `unboundChip` — только диагностика. На переходе incomplete→complete: обычный success, затем
    /// фанфары через `fanfareDelayMs` и «Готово!»-бит (§10).
    private func applyFeedback(_ event: ScanEvent, now: Int64) {
        switch event {
        case .unboundChip:
            diagnostic = "Чип не привязан к команде"
            feedback.play(feedbackFor(event: event))
        case let .badKp(reason):
            diagnostic = reason
            feedback.play(feedbackFor(event: event))
        case .kp, .member:
            diagnostic = nil
            // Если окно уже истекло на момент тапа — отбрасываем стейл-сессию, чтобы reduce стартовал с нуля.
            let effective = isWindowExpired(lastScanAt: session?.lastScanAt, now: now) ? nil : session
            let wasComplete = isComplete(session: effective, rosterSize: roster.count)
            session = reduce(session: effective, event: event, now: now)
            let nowComplete = isComplete(session: session, rosterSize: roster.count)
            feedback.play(feedbackFor(event: event))
            if !wasComplete && nowComplete {
                scheduleFanfare()
                beginCompletionHold()
            } else if !nowComplete {
                cancelCompletionHold()
            }
        }
        pushStatus()
    }

    /// Прогресс-строка системной NFC-шторки (хост толкает её в сканер по мере набора участников).
    /// Диагностика последнего тапа приоритетна; иначе «КП N · чипы X/Y», пока ждём чип КП — приглашение.
    private func pushStatus() {
        let text: String
        if let diagnostic {
            text = diagnostic
        } else if let number = checkpointNumber {
            text = "КП \(number) · чипы \(scannedSlots.count)/\(roster.count)"
        } else {
            text = "Приложите чип КП"
        }
        scanner?.setStatus(text)
    }

    private func scheduleFanfare() {
        let delay = fanfareDelayMs
        fanfareTask?.cancel()
        fanfareTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay)))
            guard let self, !Task.isCancelled else { return }
            self.feedback.fanfare()
        }
    }

    // MARK: - Автозакрытие по завершению (§10)

    private func beginCompletionHold() {
        guard !completed else { return }
        completed = true
        let hold = successHoldMs
        completionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(hold)))
            guard let self, !Task.isCancelled else { return }
            // НЕ финализируем прямо здесь: кладём событие в общий FIFO-стрим, чтобы буферизованные до него
            // чтения (смена КП у дедлайна) обработались ПЕРЕД пере-проверкой (Finding-1). Само решение —
            // в `handleCompletionCheck`, сериализованном с обработкой чтений.
            self.inputContinuation?.yield(.completionCheck)
        }
    }

    /// Пере-проверка автозакрытия из общего стрима (после холда, в порядке FIFO). Смена КП, поднятая до
    /// этого события, уже применена и отменила холд (`cancelCompletionHold` → `completed == false`).
    private func handleCompletionCheck() {
        guard completed else { return }
        if isComplete(session: session, rosterSize: roster.count) {
            // Успешное завершение (весь ростер present) — помечаем ПЕРЕД finalizeSession(), чтобы
            // `MarksView` мог отличить его от истечения окна/конца стрима и запустить конфетти после dismiss.
            didComplete = true
            finalizeSession()
            requestClose()
        } else {
            completed = false
        }
    }

    private func cancelCompletionHold() {
        completionTask?.cancel()
        completed = false
    }

    // MARK: - Таймер окна (§10)

    /// Обработка тика окна из общего стрима: пересчёт остатка по монотонному `elapsedNowMs`; на истечении
    /// (окно не продлили) — финализация + автозакрытие. Доп. записей в БД нет — марка персистована
    /// инкрементально. Сериализовано с чтениями (§7): любое чтение, поднятое ДО этого тика, уже применено,
    /// поэтому near-deadline скан продлевает окно и не теряется/не мисклассифицируется (Finding-1).
    private func handleExpiryTick() async {
        guard let last = session?.lastScanAt else {
            remainingMillis = SCAN_WINDOW_MS
            return
        }
        let elapsed = await elapsedNowMs()
        let remaining = SCAN_WINDOW_MS - (elapsed - last)
        remainingMillis = max(0, remaining)
        // Пере-проверка `lastScanAt` после await — страховка; в серийном стриме измениться не может.
        if remaining <= 0 && session?.lastScanAt == last {
            finalizeSession()
            requestClose()
        }
    }

    /// Сброс UI-сессии (не take-state — оверлей всё равно закрывается после автозакрытия).
    private func finalizeSession() {
        session = nil
        remainingMillis = SCAN_WINDOW_MS
        diagnostic = nil
        completed = false
    }

    // MARK: - GPS-attach (§3)

    /// Fire-and-forget один свежий GPS-фикс на новое взятие. Захватывает стор/провайдер (не `self`) —
    /// переживает закрытие оверлея. `nil`-фикс (нет разрешения/GPS) → no-op (`attachLocation` не зовётся).
    private func attachLocationForNewTake(markId: String, persist: Task<Void, Never>?) {
        let store = markStore
        let provider = locationProvider
        Task {
            guard let fix = await provider.current() else { return }
            // Колоночный UPDATE `WHERE id = ?` — no-op на отсутствующей строке; дожидаемся её персиста,
            // чтобы фикс не потерялся, если GPS вернулся раньше, чем `upsert` дошёл до writer'а.
            await persist?.value
            let s = sanitizeFix(fix)
            try? await store.attachLocation(
                id: markId, lat: s.lat, lon: s.lon, accuracy: s.accuracy,
                altitude: s.altitude, verticalAccuracy: s.verticalAccuracyMeters,
                gpsTimeMs: s.gpsTimeMs, elapsedRealtimeAt: s.elapsedRealtimeAt
            )
        }
    }
}
