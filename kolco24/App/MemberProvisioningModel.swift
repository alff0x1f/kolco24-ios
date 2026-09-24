//
//  MemberProvisioningModel.swift
//  kolco24
//
//  `@Observable @MainActor`-хост записи серверного кода на браслет участника «Записать браслет
//  участника» (iOS-first, Android-аналога нет; план `docs/plans/20260923-member-chip-provisioning.md`).
//  Форма — как у `ProvisioningModel` (КП): одна длинная NFC-сессия, ДВУХТАПОВЫЙ флоу. Тап 1 читает
//  UID → `bindMemberTag` (сервер выдаёт `code`) → сканер вооружается pending-write записью K24 типа
//  `CHIP_TYPE_PARTICIPANT` → «Приложите браслет ещё раз»; тап 2 сверяет ТОТ ЖЕ UID → сканер делает
//  `writeRecord` + read-back и отдаёт исход в `TagReading.writeResult`.
//
//  Два режима в одном флоу (состояния — `Core/Admin/MemberProvisioningLogic`): UID «известен» (есть
//  в наблюдаемом пуле `member_tags` ИЛИ записан в этой сессии — пул не обновится до refresh) → запрос
//  с `number: null`; иначе (или сервер ответил `404` на `null`) → `needsNumber`, админ вводит номер
//  (`confirmNumber`), поле префиллится `nextNumber` (автоинкремент после успешной записи).
//  Пул наблюдается с null-sentinel (`loaded`): сканы до первой эмиссии игнорируются. Тап чипа КП
//  (`reading.code != nil`) отклоняется «Это чип КП» — иначе bind + запись затёрли бы запись КП.
//  Сбой чтения тапа 1 (`readFailed`) → «приложите снова» без bind; перед записью сканер сам сверяет тип
//  (`writeGuardDecision` → `.wrongType`). Только что записанный браслет (`lastWrittenUid`), оставленный
//  на телефоне, игнорируется до чтения другого UID / «Отмена».
//
//  Системная NFC-шторка МОДАЛЬНА: под ней поле номера не получает ни тапов, ни клавиатуры. Поэтому
//  вход в `needsNumber` ПРИОСТАНАВЛИВАЕТ сканирование (`scanner.stop()` → шторка уходит), а
//  `confirmNumber`/`cancel` возобновляют его (`resumeScanning`: барьер `waitUntilStopped()` → свежий
//  `readings()` + `start()`). Закрытие шторки пользователем (поток кончился) → `scanning == false`,
//  вьюха показывает «Сканировать» (`resumeScanning`); pending-write при этом не теряется. Все подсказки
//  зоны скана дублируются в шторку (`setStatus(memberProvisionStatusLine)`), т.к. экран под ней не виден.
//
//  Сетевой bind — в НЕструктурированном `Task`, захватывающем ЗАМЫКАНИЕ `bindMemberTag` (`[weak self]`
//  лишь для обновления состояния): уход с экрана не рвёт серверную привязку (§6); результат после
//  `stop()`/`cancel()` отбрасывается (`Task.isCancelled`). Чтения сериализованы единым `for await`.
//
//  `import SwiftUI`/`GRDB`/`CoreNFC` запрещены (grep-инвариант) — хватает `Observation`/`Foundation`.
//  Прод-сканер `NfcChipScanner` инстанцируется фабрикой `AppModel.makeMemberProvisioningModel`.
//

import Foundation
import Observation

@MainActor
@Observable
final class MemberProvisioningModel: Identifiable {

    /// Стабильный id (навигация/`Identifiable`).
    nonisolated let id = UUID()

    /// Пара «браслет → номер»: записанный в этой сессии браслет (лента пилюль «№101 · A1B2»,
    /// `id` — UID, дедуп ленты) либо номер, введённый для браслета (`lastRequested`).
    struct FreshBracelet: Equatable, Identifiable {
        let uid: String
        let number: Int
        var id: String { uid }
    }

    // MARK: - UI-состояние (observable)

    /// Состояние текущего браслета (двухтаповый флоу + ввод номера).
    private(set) var provisionState: MemberProvisionState = .waitingForChip {
        didSet { pushStatus() }
    }
    /// Подсказка зоны скана в `waitingForWrite` (тап 2). `nil` — без подсказки.
    private(set) var writeHint: String? {
        didSet { pushStatus() }
    }
    /// Открыта (или открывается) NFC-сессия. `false` — приостановлено в `needsNumber` либо пользователь
    /// закрыл системную шторку; вьюха предлагает «Сканировать» (`resumeScanning`).
    private(set) var scanning = false
    /// Префилл поля номера: `nil` (пустое поле) до первой успешной записи, затем `number + 1`.
    private(set) var nextNumber: Int?
    /// Записанные в этой сессии браслеты, новые сверху, капится `feedCap`; дедуп по UID.
    private(set) var freshFeed: [FreshBracelet] = []
    /// Загрузился ли пул (первая эмиссия observation). До этого сканы игнорируются.
    private(set) var loaded = false
    /// Размер пула `member_tags` (idle-строка; `0` — признак «пул не синхронизирован»).
    private(set) var poolSize = 0
    /// Просьба закрыть экран в форму логина (после 401). Вьюха дисмиссит.
    private(set) var closeRequested = false

    /// Потокобезопасное зеркало «экран жив» для `NfcChipScanner.shouldRestart`.
    @ObservationIgnored let liveness = ScanLiveness(alive: true)

    // MARK: - Пул (не-observable, null-sentinel)

    /// UID-множество пула браслетов гонки; осмысленно лишь при `loaded`.
    @ObservationIgnored private var poolUids: Set<String> = []
    /// Последний введённый номер для UID (префилл при повторном `needsNumber` того же браслета после
    /// сбоя bind — чтобы не подставить устаревший автоинкремент).
    @ObservationIgnored private var lastRequested: FreshBracelet?
    /// UID последнего успешно записанного браслета. Сканер после каждого чтения `restartPolling()` —
    /// браслет, оставленный на телефоне, детектится снова, как только кончится дебаунс; без этого
    /// фильтра он бы пере-привязался и пере-записался (прерванная перезапись зануляет заголовок).
    /// Его чтения игнорируются, пока не прочитан ДРУГОЙ UID или не нажата «Отмена».
    @ObservationIgnored private var lastWrittenUid: String?

    // MARK: - Зависимости

    @ObservationIgnored let raceId: Int
    @ObservationIgnored private let memberTagStore: MemberTagStore
    /// `POST /app/race/<id>/member_tags/bind/` на cloud-клиенте: (`raceId`, `nfcUid`, `number`).
    @ObservationIgnored private let bindMemberTag: (Int, String, Int?) async -> PostResult<MemberTagBindResponse>
    /// 401 посреди записи: `AdminAuthRepository.onUnauthorized()` (чистит сессию → форма логина).
    @ObservationIgnored private let onUnauthorized: () -> Void
    @ObservationIgnored private let feedback: any ScanFeedbackPlaying
    /// Пауза «успех» перед возвратом в `waitingForChip` (инжектится, чтобы тесты не ждали реальную).
    @ObservationIgnored private let successHoldMs: Int

    // MARK: - Задачи

    @ObservationIgnored private var scanner: (any ProvisioningScanning)?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var poolTask: Task<Void, Never>?
    @ObservationIgnored private var bindTask: Task<Void, Never>?
    @ObservationIgnored private var advanceTask: Task<Void, Never>?
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    /// Поколение потока чтений: конец СТАРОГО потока (после suspend/рестарта) не сбрасывает `scanning`.
    @ObservationIgnored private var streamGen = 0
    /// Экран закрыт (`stop()`): отложенный `resumeScanning` не должен открыть шторку.
    @ObservationIgnored private var closed = false

    /// Пауза «успех» по умолчанию (мс).
    static let defaultSuccessHoldMs = 1200
    /// Максимум записей в ленте свежих браслетов.
    static let feedCap = 20

    init(
        raceId: Int,
        memberTagStore: MemberTagStore,
        bindMemberTag: @escaping (Int, String, Int?) async -> PostResult<MemberTagBindResponse>,
        onUnauthorized: @escaping () -> Void,
        feedback: any ScanFeedbackPlaying,
        successHoldMs: Int = MemberProvisioningModel.defaultSuccessHoldMs
    ) {
        self.raceId = raceId
        self.memberTagStore = memberTagStore
        self.bindMemberTag = bindMemberTag
        self.onUnauthorized = onUnauthorized
        self.feedback = feedback
        self.successHoldMs = successHoldMs
        startPoolObservation()
    }

    deinit {
        liveness.set(false)
        streamTask?.cancel()
        poolTask?.cancel()
        bindTask?.cancel()
        advanceTask?.cancel()
        resumeTask?.cancel()
        scanner?.stop()
    }

    // MARK: - Жизненный цикл

    /// Тестовый вход: стартует сканирование по инжектированному [scanner].
    /// Повторно входим: старый поток (если был) отменяется, берётся свежий `readings()`.
    func start(scanner: any ProvisioningScanning) {
        self.scanner = scanner
        closed = false
        liveness.set(true)
        streamTask?.cancel()
        streamGen += 1
        let gen = streamGen
        let readings = scanner.readings()
        pushStatus() // до start(): шторка открывается с актуальной строкой, а не «Приложите чип КП»
        scanner.start()
        scanning = true
        streamTask = Task { [weak self] in
            for await reading in readings {
                guard let self else { return }
                await self.processReading(reading)
            }
            // Поток кончился не по воле модели (пользователь закрыл шторку / NFC недоступен).
            guard let self, self.streamGen == gen else { return }
            self.scanning = false
        }
    }

    /// Привязать прод-сканер (`AppModel.makeMemberProvisioningModel`); вьюха стартует `beginScanning()`.
    func attachProductionScanner(_ scanner: any ProvisioningScanning) {
        self.scanner = scanner
    }

    /// Старт привязанного прод-сканера (вьюха, `.task`). No-op без сканера.
    func beginScanning() {
        guard let scanner else { return }
        start(scanner: scanner)
    }

    /// Закрытие экрана: гасит liveness, отменяет задачи (поздний bind-результат отбрасывается),
    /// разоружает pending-write и останавливает сканер.
    func stop() {
        closed = true
        liveness.set(false)
        streamGen += 1
        scanning = false
        streamTask?.cancel()
        streamTask = nil
        resumeTask?.cancel()
        resumeTask = nil
        bindTask?.cancel()
        advanceTask?.cancel()
        scanner?.clearPendingWrite()
        scanner?.stop()
    }

    /// Приостановить сессию (вход в `needsNumber`): модальная шторка уходит, поле номера доступно.
    private func suspendScanning() {
        streamGen += 1
        scanning = false
        resumeTask?.cancel()
        resumeTask = nil
        streamTask?.cancel()
        streamTask = nil
        scanner?.stop()
    }

    /// Возобновить сканирование («Сканировать» / `confirmNumber` / `cancel`). No-op, если сессия уже
    /// открыта/открывается, экран закрыт или сканера нет. Барьер `waitUntilStopped()` — прежняя
    /// платформенная сессия должна фактически инвалидироваться, иначе её поздний `didInvalidate`
    /// завершил бы уже новый поток.
    func resumeScanning() {
        guard !closed, !scanning, let scanner else { return }
        scanning = true
        resumeTask = Task { [weak self] in
            await scanner.waitUntilStopped()
            guard let self, !Task.isCancelled, !self.closed else { return }
            self.resumeTask = nil
            self.start(scanner: scanner)
        }
    }

    // MARK: - Действия вьюхи

    /// «Привязать» с введённым номером [n]. Только в `needsNumber` и при `n >= 1`, иначе no-op.
    /// Возобновляет сканирование (тап 2 требует открытой шторки).
    func confirmNumber(_ n: Int) {
        guard case let .needsNumber(uid) = provisionState, n >= 1 else { return }
        lastRequested = FreshBracelet(uid: uid, number: n)
        startBind(uid: uid, number: n)
        resumeScanning()
    }

    /// Префилл поля номера для [uid]: номер, уже введённый для этого браслета (повтор после сбоя bind),
    /// иначе автоинкремент `nextNumber`.
    func prefillNumber(for uid: String) -> Int? {
        if let lastRequested, lastRequested.uid == uid { return lastRequested.number }
        return nextNumber
    }

    /// «Отмена»: бросить текущий браслет — разоружить pending-write, отменить автовозврат, вернуться в
    /// `waitingForChip` и возобновить сканирование. Во время `binding` — no-op (результат сервера не
    /// выбрасываем: привязка уже могла состояться).
    func cancel() {
        if case .binding = provisionState { return }
        lastWrittenUid = nil
        resetChipState()
        resumeScanning()
    }

    private func resetChipState() {
        provisionState = .waitingForChip
        writeHint = nil
        bindTask?.cancel()
        advanceTask?.cancel()
        scanner?.clearPendingWrite()
    }

    // MARK: - Наблюдение пула

    private func startPoolObservation() {
        let observation = memberTagStore.observeForRace(raceId)
        poolTask = Task { [weak self] in
            do {
                for try await tags in observation {
                    guard let self, !Task.isCancelled else { return }
                    self.poolUids = Set(tags.map(\.nfcUid))
                    self.poolSize = self.poolUids.count
                    self.loaded = true
                }
            } catch {}
        }
    }

    /// UID «известен»: есть в пуле или записан в этой сессии (пул до refresh его не содержит; повтор
    /// с `number: null` сервер отдаёт как `200`).
    private func isKnown(_ uid: String) -> Bool {
        poolUids.contains(uid) || freshFeed.contains { $0.uid == uid }
    }

    // MARK: - Обработка одного чтения

    /// Один прочитанный браслет. До первой эмиссии пула — игнор. `waitingForChip`/`failed` →
    /// маршрутизация по «известен»; `needsNumber` + другой UID → та же маршрутизация (тот же — игнор;
    /// сюда доходит лишь чтение, успевшее до приостановки сессии); `waitingForWrite` → сверка UID +
    /// исход записи; `binding`/`success` → игнор.
    func processReading(_ reading: TagReading) async {
        guard loaded else { return }
        switch provisionState {
        case .waitingForChip, .failed:
            route(reading)
        case let .needsNumber(uid):
            if reading.uid != uid { route(reading) }
        case let .waitingForWrite(uid, number):
            handleWriteTap(reading: reading, expectedUid: uid, number: number)
        case .binding, .success:
            break
        }
    }

    /// Только что записанный браслет (всё ещё лежит на телефоне) → тихий игнор. Сбой чтения → просьба
    /// приложить снова (без bind: чип КП с плохим контактом выглядел бы пустым браслетом). Чип КП
    /// (прочитан K24-код КП) → отказ: bind + запись заменили бы запись КП кодом участника.
    private func route(_ reading: TagReading) {
        let uid = reading.uid
        if uid == lastWrittenUid { return }
        lastWrittenUid = nil
        writeHint = nil
        if reading.readFailed {
            provisionState = .failed(reason: ProvisionMessage.readFailedTapAgain)
            feedback.play(.failure)
        } else if reading.code != nil {
            provisionState = .failed(reason: ProvisionMessage.kpChipNotBracelet)
            feedback.play(.failure)
        } else if isKnown(uid) {
            startBind(uid: uid, number: nil)
        } else {
            enterNeedsNumber(uid: uid)
        }
    }

    /// `needsNumber` + приостановка сессии (под модальной шторкой номер не ввести).
    private func enterNeedsNumber(uid: String) {
        provisionState = .needsNumber(uid: uid)
        suspendScanning()
    }

    /// Перевести в `binding` и запустить `bindMemberTag` в НЕструктурированном Task (захват замыкания, §6).
    private func startBind(uid: String, number: Int?) {
        writeHint = nil
        provisionState = .binding(uid: uid, number: number)
        let bind = bindMemberTag
        let rid = raceId
        bindTask?.cancel()
        bindTask = Task { [weak self] in
            let result = await bind(rid, uid, number)
            guard let self, !Task.isCancelled else { return }
            self.finishBind(uid: uid, requestedNumber: number, result: result)
        }
    }

    /// Результат bind: success → запись K24 типа PARTICIPANT в pending-write + `waitingForWrite`;
    /// битый hex → «Неверный код от сервера»; `404` на `number: null` → `needsNumber`; 401 →
    /// onUnauthorized + закрытие; прочее → `failed(memberProvisionErrorMessage)`.
    private func finishBind(uid: String, requestedNumber: Int?, result: PostResult<MemberTagBindResponse>) {
        switch result {
        case let .success(response):
            do {
                let code = try chipCodeFromHex(response.code)
                let record = try buildChipRecord(type: CHIP_TYPE_PARTICIPANT, code: code)
                scanner?.setPendingWrite(uid: uid, record: record)
                provisionState = .waitingForWrite(uid: uid, number: response.number)
                writeHint = ProvisionMessage.memberWriteAgainHint
            } catch {
                provisionState = .failed(reason: "Неверный код от сервера")
                feedback.play(.failure)
            }
        case .error(let code) where code == 404 && requestedNumber == nil:
            // Сервер не знает UID (пул устарел) — просим номер.
            enterNeedsNumber(uid: uid)
        case .unauthorized:
            onUnauthorized()
            closeRequested = true
        default:
            provisionState = .failed(reason: memberProvisionErrorMessage(result))
            feedback.play(.failure)
        }
    }

    /// Тап 2: чужой UID → «Приложите тот же браслет» (сканер пишет лишь при совпадении UID); свой +
    /// `.success` → успех; иначе → остаёмся в `waitingForWrite`, pending-write СОХРАНЁН (header-last).
    private func handleWriteTap(reading: TagReading, expectedUid: String, number: Int) {
        if reading.uid != expectedUid {
            writeHint = "Приложите тот же браслет"
            feedback.play(.failure)
            return
        }
        switch reading.writeResult {
        case .success:
            completeWrite(uid: expectedUid, number: number)
        case let .wrongType(reason):
            // Pre-write guard сканера: на чипе запись другого типа — ничего не записано, чип бросаем.
            scanner?.clearPendingWrite()
            writeHint = nil
            provisionState = .failed(reason: reason)
            feedback.play(.failure)
        case .readFailed:
            // Pre-write чтение не удалось — ничего не записано, pending-write сохранён.
            writeHint = ProvisionMessage.readFailedTapAgain
            feedback.play(.failure)
        case .failed, .unsupported, .none:
            writeHint = ProvisionMessage.writeFailedTapAgain
            feedback.play(.failure)
        }
    }

    /// Запись подтверждена read-back'ом: лента (дедуп по UID — замена + наверх), автоинкремент номера,
    /// `success(number)`, разоружение сканера, фидбек успеха (без фанфар), возврат в `waitingForChip` после паузы.
    private func completeWrite(uid: String, number: Int) {
        freshFeed.removeAll { $0.uid == uid }
        freshFeed.insert(FreshBracelet(uid: uid, number: number), at: 0)
        if freshFeed.count > Self.feedCap {
            freshFeed.removeLast(freshFeed.count - Self.feedCap)
        }
        nextNumber = number == Int.max ? nil : number + 1
        if lastRequested?.uid == uid { lastRequested = nil }
        lastWrittenUid = uid
        provisionState = .success(number: number)
        writeHint = nil
        scanner?.clearPendingWrite()
        feedback.play(.success)
        scheduleReturn()
    }

    /// Строка системной NFC-шторки по текущему состоянию (экран под модальной шторкой не виден).
    private func pushStatus() {
        scanner?.setStatus(memberProvisionStatusLine(provisionState, hint: writeHint))
    }

    private func scheduleReturn() {
        advanceTask?.cancel()
        let hold = successHoldMs
        advanceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(hold))
            guard let self, !Task.isCancelled else { return }
            self.resetChipState()
        }
    }
}
