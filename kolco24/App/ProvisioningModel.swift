//
//  ProvisioningModel.swift
//  kolco24
//
//  `@Observable @MainActor`-хост-редьюсер провижининга «Привязка чипов» (этап 10). Порт ПОВЕДЕНИЯ
//  (не структуры) `ui/admin/ProvisioningModel.kt` + `ProvisioningScreen.kt`: список КП гонки + одна
//  длинная NFC-сессия → привязка физического чипа к выбранному КП с записью выданного сервером кода.
//
//  DEVIATION от Android — ДВУХТАПОВЫЙ флоу (см. `Core/Admin/ProvisioningLogic`): тап 1 читает UID →
//  `bindTag` (сервер выдаёт `code`) → сканер вооружается pending-write ячейкой → «Приложите чип ещё
//  раз»; тап 2 сверяет ТОТ ЖЕ UID (чужой чип → отказ БЕЗ записи) → сканер делает `writeRecord` +
//  read-back и отдаёт исход в `TagReading.writeResult`. Надёжно при медленной сети; header-last
//  гарантирует безопасность повтора тапа 2 (`writeRecord` инвалидирует заголовок до дозаписи кода).
//
//  Счётчики «уже привязано» — из наблюдаемого `tags` (кэш) + свежезаписанные за сессию (`freshUids`,
//  per-КП). max/subtract-логика против ДВОЙНОГО счёта после mid-session refresh легенды (порт
//  `ProvisioningScreen.kt` :351/:388): rail-покрытие = `max(cached, fresh)`, «Уже привязано: N» =
//  `max(0, cached − fresh)` (после refresh сервер доставит свежие теги в кэш — вычитание убирает
//  дубль).
//
//  Сетевой bind — в НЕструктурированном `Task`, захватывающем ЗАМЫКАНИЕ `bindTag` (не `self` строго,
//  а `[weak self]` для обновления состояния): уход с экрана не рвёт серверную привязку (§6-идиома;
//  локальной записи в БД у bind нет — результат при закрытии просто отбрасывается). Обработка чтений
//  сериализована единым `for await` по стриму сканера.
//
//  `import SwiftUI`/`GRDB`/`CoreNFC` запрещены (grep-инвариант) — хватает `Observation`/`Foundation`;
//  модель зависит от `Core/`-логики + сторов + инжектированных замыканий (`bindTag`/`onUnauthorized`).
//  Прод-сканер `NfcChipScanner` инстанцируется фабрикой `AppModel.makeProvisioningModel`.
//

import Foundation
import Observation

@MainActor
@Observable
final class ProvisioningModel: Identifiable {

    /// Стабильный id (навигация/`Identifiable`).
    nonisolated let id = UUID()

    // MARK: - UI-состояние (observable)

    /// КП гонки (порядок `number, id`) — источник степпера. Пустой до первой эмиссии observation.
    private(set) var checkpoints: [Checkpoint] = []
    /// Индекс выбранного КП в [checkpoints]. Автопереход к следующему после успешной записи.
    private(set) var selectedIndex = 0 {
        didSet { pushStatus() }
    }
    /// Состояние провижинимого чипа против выбранного КП (двухтаповый флоу).
    private(set) var provisionState: ProvisionState = .waitingForChip {
        didSet { pushStatus() }
    }
    /// Вспомогательная подсказка зоны скана в `waitingForWrite` (тап 2): «Приложите тот же чип» /
    /// «Не удалось записать, приложите снова». `nil` — без подсказки.
    private(set) var writeHint: String? {
        didSet { pushStatus() }
    }
    /// Открыта (или открывается) NFC-сессия. `false` — пользователь закрыл системную шторку (например,
    /// чтобы выбрать другой КП в степпере); вьюха предлагает «Сканировать» (`resumeScanning`).
    private(set) var scanning = false
    /// UID-множества свежезаписанных за сессию чипов, per-КП (`checkpoint.id`). Драйвит зелёные пилюли
    /// и участвует в max/subtract-логике счётчиков.
    private(set) var freshUids: [Int: [String]] = [:]
    /// Загрузились ли КП (первая эмиссия observation) — вьюха показывает «Загрузка КП…» до этого.
    private(set) var loaded = false
    /// Просьба закрыть экран в форму логина (после 401 — сессия отозвана/протухла). Вьюха дисмиссит.
    private(set) var closeRequested = false

    /// Потокобезопасное зеркало «экран жив» для `NfcChipScanner.shouldRestart`.
    @ObservationIgnored let liveness = ScanLiveness(alive: true)

    // MARK: - Кэш тегов (не-observable)

    /// Число привязанных тегов per-КП (`checkpoint.id`) из наблюдаемого `tags` — «кэш» (серверная правда).
    @ObservationIgnored private var cachedCounts: [Int: Int] = [:]
    /// Человеко-читаемый номер КП, выданный сервером на тапе 1 — переносится в `success(number:)` на тапе 2.
    @ObservationIgnored private var pendingWriteNumber: Int?
    /// UID последнего успешно записанного чипа: оставленный на телефоне, он детектится снова после
    /// дебаунса (`restartPolling`) и без фильтра привязался бы к СЛЕДУЮЩЕМУ КП (автопереход) с
    /// перезаписью. Игнорируется, пока не прочитан другой UID или админ сам не выбрал КП в степпере.
    @ObservationIgnored private var lastWrittenUid: String?

    // MARK: - Зависимости

    @ObservationIgnored let raceId: Int
    @ObservationIgnored private let checkpointStore: CheckpointStore
    @ObservationIgnored private let tagStore: TagStore
    /// `POST /app/race/<id>/tags/` на cloud-клиенте: привязать `nfcUid` к КП `checkpointId`.
    @ObservationIgnored private let bindTag: (Int, Int, String) async -> PostResult<TagBindResponse>
    /// 401 посреди провижининга: `AdminAuthRepository.onUnauthorized()` (чистит сессию → форма логина).
    @ObservationIgnored private let onUnauthorized: () -> Void
    @ObservationIgnored private let feedback: any ScanFeedbackPlaying
    /// Пауза «успех» перед автопереходом к следующему КП (инжектится, чтобы тесты не ждали реальную).
    @ObservationIgnored private let successHoldMs: Int

    // MARK: - Задачи

    @ObservationIgnored private var scanner: (any ProvisioningScanning)?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var cpTask: Task<Void, Never>?
    @ObservationIgnored private var tagsTask: Task<Void, Never>?
    @ObservationIgnored private var bindTask: Task<Void, Never>?
    @ObservationIgnored private var advanceTask: Task<Void, Never>?
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    /// Поколение потока чтений: конец СТАРОГО потока (после рестарта) не сбрасывает `scanning`.
    @ObservationIgnored private var streamGen = 0
    /// Экран закрыт (`stop()`): отложенный `resumeScanning` не должен открыть шторку.
    @ObservationIgnored private var closed = false

    /// Пауза «успех» по умолчанию перед автопереходом (мс).
    static let defaultSuccessHoldMs = 1200
    /// Максимум пилюль свежих чипов, показываемых во вью (косметика; хранение не капится).
    static let feedCap = 20

    init(
        raceId: Int,
        checkpointStore: CheckpointStore,
        tagStore: TagStore,
        bindTag: @escaping (Int, Int, String) async -> PostResult<TagBindResponse>,
        onUnauthorized: @escaping () -> Void,
        feedback: any ScanFeedbackPlaying,
        successHoldMs: Int = ProvisioningModel.defaultSuccessHoldMs
    ) {
        self.raceId = raceId
        self.checkpointStore = checkpointStore
        self.tagStore = tagStore
        self.bindTag = bindTag
        self.onUnauthorized = onUnauthorized
        self.feedback = feedback
        self.successHoldMs = successHoldMs
        startObservation()
    }

    deinit {
        liveness.set(false)
        streamTask?.cancel()
        cpTask?.cancel()
        tagsTask?.cancel()
        bindTask?.cancel()
        advanceTask?.cancel()
        resumeTask?.cancel()
        scanner?.stop()
    }

    // MARK: - Производные

    /// Выбранный КП (или `nil`, пока список пуст).
    var selectedCheckpoint: Checkpoint? {
        guard selectedIndex >= 0, selectedIndex < checkpoints.count else { return nil }
        return checkpoints[selectedIndex]
    }

    /// «Уже привязано: N» для КП — вычитает свежие за сессию из кэша (после refresh легенды сервер
    /// доставит свежие теги в кэш; без вычитания счёт задвоился бы). Порт `preSeededCount` (:388).
    func alreadyBound(_ cp: Checkpoint) -> Int {
        max(0, (cachedCounts[cp.id] ?? 0) - (freshUids[cp.id]?.count ?? 0))
    }

    /// Метки свежезаписанных за сессию чипов КП (последние 4 hex), для зелёных пилюль.
    func freshLabels(_ cp: Checkpoint) -> [String] {
        (freshUids[cp.id] ?? []).map { chipTokenLabel(uid: $0) }
    }

    /// Есть ли у КП хоть один привязанный чип (кэш ИЛИ свежий) — для «заполненной» отметки степпера.
    /// Порт rail-покрытия `max(cached, fresh) > 0` (:352).
    func hasAnyChip(_ cp: Checkpoint) -> Bool {
        max(cachedCounts[cp.id] ?? 0, freshUids[cp.id]?.count ?? 0) > 0
    }

    // MARK: - Жизненный цикл

    /// Тестовый вход: стартует сканирование по инжектированному [scanner] (`FakeProvisioningScanner`).
    /// Повторно входим: старый поток (если был) отменяется, берётся свежий `readings()`.
    func start(scanner: any ProvisioningScanning) {
        self.scanner = scanner
        closed = false
        liveness.set(true)
        streamTask?.cancel()
        streamGen += 1
        let gen = streamGen
        let readings = scanner.readings()
        pushStatus() // до start(): шторка открывается с номером выбранного КП
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

    /// Привязать прод-сканер (`AppModel.makeProvisioningModel`); вьюха стартует `beginScanning()`.
    func attachProductionScanner(_ scanner: any ProvisioningScanning) {
        self.scanner = scanner
    }

    /// Старт привязанного прод-сканера (вьюха, `.task`). No-op без сканера.
    func beginScanning() {
        guard let scanner else { return }
        start(scanner: scanner)
    }

    /// Закрытие экрана: гасит liveness, отменяет задачи, разоружает pending-write и останавливает сканер.
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

    /// Возобновить сканирование («Сканировать»). No-op, если сессия уже открыта/открывается, экран
    /// закрыт или сканера нет. Барьер `waitUntilStopped()` — прежняя платформенная сессия должна
    /// фактически инвалидироваться, иначе её поздний `didInvalidate` завершил бы уже новый поток.
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

    // MARK: - Выбор КП (степпер)

    /// Перейти на КП по индексу: сбрасывает состояние чипа в `waitingForChip` и РАЗОРУЖАЕТ pending-write
    /// (иначе чип, вооружённый для прежнего КП, записался бы на новый). No-op при выходе за границы.
    func selectCheckpoint(index: Int) {
        guard index >= 0, index < checkpoints.count else { return }
        lastWrittenUid = nil
        moveToCheckpoint(index: index)
    }

    private func moveToCheckpoint(index: Int) {
        selectedIndex = index
        resetChipState()
    }

    private func resetChipState() {
        provisionState = .waitingForChip
        writeHint = nil
        pendingWriteNumber = nil
        bindTask?.cancel()
        advanceTask?.cancel()
        scanner?.clearPendingWrite()
    }

    // MARK: - Наблюдение (КП + теги)

    private func startObservation() {
        let cpObs = checkpointStore.observeCheckpointsForRace(raceId)
        cpTask = Task { [weak self] in
            do {
                for try await rows in cpObs {
                    guard let self, !Task.isCancelled else { return }
                    self.checkpoints = rows
                    self.loaded = true
                    self.pushStatus()
                    // Держим selectedIndex в границах после смены легенды.
                    if self.selectedIndex >= rows.count {
                        self.selectedIndex = max(0, rows.count - 1)
                    }
                }
            } catch {}
        }
        let tagsObs = tagStore.observeTagsForRace(raceId)
        tagsTask = Task { [weak self] in
            do {
                for try await rows in tagsObs {
                    guard let self, !Task.isCancelled else { return }
                    var counts: [Int: Int] = [:]
                    for t in rows { counts[t.checkpointId, default: 0] += 1 }
                    self.cachedCounts = counts
                }
            } catch {}
        }
    }

    // MARK: - Обработка одного чтения (двухтаповый флоу)

    /// Один прочитанный чип. Тап 1 (`waitingForChip`/`failed` — повтор) → bind (браслет с кодом участника —
    /// `memberCode != nil` — отклоняется «Это браслет участника»); тап 2 (`waitingForWrite`)
    /// → сверка UID + исход записи. Во время `binding`/`success` чтения игнорируются (сериализовано `for await`).
    func processReading(_ reading: TagReading) async {
        switch provisionState {
        case .waitingForChip, .failed:
            // Только что записанный чип всё ещё на телефоне — тихий игнор (иначе ре-bind к след. КП).
            if reading.uid == lastWrittenUid { return }
            lastWrittenUid = nil
            // Сбой чтения: браслет с плохим контактом выглядел бы пустым чипом — bind не начинаем.
            if reading.readFailed {
                writeHint = nil
                provisionState = .failed(reason: ProvisionMessage.readFailedTapAgain)
                feedback.play(.failure)
                return
            }
            // Браслет с записанным кодом участника — не перезаписываем его записью КП.
            if reading.memberCode != nil {
                writeHint = nil
                provisionState = .failed(reason: ProvisionMessage.memberBracelet)
                feedback.play(.failure)
                return
            }
            startBind(uid: reading.uid)
        case let .waitingForWrite(uid, _):
            handleWriteTap(reading: reading, expectedUid: uid)
        case .binding, .success:
            break
        }
    }

    /// Тап 1: перевести в `binding`, вооружить `bindTag` в НЕструктурированном Task (захват замыкания,
    /// `[weak self]` для обновления состояния — уход с экрана не рвёт серверную привязку, §6).
    private func startBind(uid: String) {
        guard let cp = selectedCheckpoint else { return }
        writeHint = nil
        provisionState = .binding(uid: uid)
        let bind = bindTag
        let rid = raceId
        let cpId = cp.id
        bindTask?.cancel()
        bindTask = Task { [weak self] in
            let result = await bind(rid, cpId, uid)
            guard let self, !Task.isCancelled else { return }
            self.finishBind(uid: uid, result: result)
        }
    }

    /// Результат `bindTag`: success → распаковать hex-код, собрать запись, вооружить сканер и перейти в
    /// `waitingForWrite`; битый hex → «Неверный код от сервера»; 401 → onUnauthorized + закрытие;
    /// прочее → `failed(provisionErrorMessage)`.
    private func finishBind(uid: String, result: PostResult<TagBindResponse>) {
        switch result {
        case let .success(response):
            do {
                let code = try chipCodeFromHex(response.code)
                let record = try buildChipRecord(type: CHIP_TYPE_KP, code: code)
                pendingWriteNumber = response.number
                scanner?.setPendingWrite(uid: uid, record: record)
                provisionState = .waitingForWrite(uid: uid, code: response.code)
                writeHint = ProvisionMessage.kpWriteAgainHint
            } catch {
                provisionState = .failed(reason: "Неверный код от сервера")
                feedback.play(.failure)
            }
        case .unauthorized:
            onUnauthorized()
            closeRequested = true
        default:
            provisionState = .failed(reason: provisionErrorMessage(result))
            feedback.play(.failure)
        }
    }

    /// Тап 2: чужой UID → «Приложите тот же чип» (без записи — сканер пишет лишь при совпадении UID);
    /// совпал + `writeResult == .success` → успех + автопереход; иначе (`failed`/`unsupported`/`nil`) →
    /// остаёмся в `waitingForWrite`, pending-write СОХРАНЁН (повтор безопасен, header-last).
    private func handleWriteTap(reading: TagReading, expectedUid: String) {
        if reading.uid != expectedUid {
            writeHint = "Приложите тот же чип"
            feedback.play(.failure)
            return
        }
        switch reading.writeResult {
        case .success:
            completeWrite(uid: expectedUid)
        case let .wrongType(reason):
            // Pre-write guard сканера: на чипе запись другого типа — ничего не записано, чип бросаем.
            scanner?.clearPendingWrite()
            pendingWriteNumber = nil
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

    /// Запись прошла + подтверждена read-back'ом: пометить чип свежим, `success(number)`, разоружить
    /// сканер, фидбек успеха (без фанфар), запланировать автопереход к следующему КП.
    private func completeWrite(uid: String) {
        if let cp = selectedCheckpoint, !(freshUids[cp.id] ?? []).contains(uid) {
            // Дедуп per-КП (порт `if (uid !in existing)` из ProvisioningScreen.kt): повторная запись
            // ТОГО ЖЕ чипа в одной сессии не должна задваивать свежий pill и пере-вычитать «Уже
            // привязано: N» (max/subtract-математика полагается на уникальные uid).
            freshUids[cp.id, default: []].append(uid)
        }
        let number = pendingWriteNumber ?? selectedCheckpoint?.number ?? 0
        provisionState = .success(number: number)
        writeHint = nil
        pendingWriteNumber = nil
        lastWrittenUid = uid
        scanner?.clearPendingWrite()
        feedback.play(.success)
        scheduleAutoAdvance()
    }

    /// Строка системной NFC-шторки: шторка модальна и закрывает степпер — номер КП дублируется в ней.
    private func pushStatus() {
        scanner?.setStatus(kpProvisionStatusLine(provisionState, number: selectedCheckpoint?.number, hint: writeHint))
    }

    private func scheduleAutoAdvance() {
        advanceTask?.cancel()
        let hold = successHoldMs
        advanceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(hold))
            guard let self, !Task.isCancelled else { return }
            self.advanceToNext()
        }
    }

    /// Автопереход к следующему КП после успеха (последний КП → остаёмся, но сбрасываем состояние чипа).
    private func advanceToNext() {
        guard !checkpoints.isEmpty else { resetChipState(); return }
        let next = min(selectedIndex + 1, checkpoints.count - 1)
        moveToCheckpoint(index: next) // не selectCheckpoint: lastWrittenUid переживает автопереход
    }
}
