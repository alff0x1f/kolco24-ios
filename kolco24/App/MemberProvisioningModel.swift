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
//  Пул наблюдается с null-sentinel (`pool == nil`): сканы до первой эмиссии игнорируются.
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

    /// Браслет, записанный в этой сессии (лента пилюль «№101 · A1B2»). `id` — UID (дедуп ленты).
    struct FreshBracelet: Equatable, Identifiable {
        let uid: String
        let number: Int
        var id: String { uid }
    }

    // MARK: - UI-состояние (observable)

    /// Состояние текущего браслета (двухтаповый флоу + ввод номера).
    private(set) var provisionState: MemberProvisionState = .waitingForChip
    /// Подсказка зоны скана в `waitingForWrite` (тап 2). `nil` — без подсказки.
    private(set) var writeHint: String?
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

    /// UID-множество пула браслетов гонки; `nil` до первой эмиссии observation.
    @ObservationIgnored private var poolUids: Set<String>?

    // MARK: - Зависимости

    @ObservationIgnored let raceId: Int
    @ObservationIgnored private let memberTagStore: MemberTagStore
    /// `POST /app/race/<id>/member_tags/` на cloud-клиенте: (`raceId`, `nfcUid`, `number`).
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
        scanner?.stop()
    }

    // MARK: - Жизненный цикл

    /// Тестовый вход: стартует сканирование по инжектированному [scanner].
    func start(scanner: any ProvisioningScanning) {
        self.scanner = scanner
        liveness.set(true)
        let readings = scanner.readings()
        scanner.start()
        streamTask = Task { [weak self] in
            for await reading in readings {
                guard let self else { return }
                await self.processReading(reading)
            }
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
        liveness.set(false)
        streamTask?.cancel()
        streamTask = nil
        bindTask?.cancel()
        advanceTask?.cancel()
        scanner?.clearPendingWrite()
        scanner?.stop()
    }

    // MARK: - Действия вьюхи

    /// «Привязать» с введённым номером [n]. Только в `needsNumber` и при `n >= 1`, иначе no-op.
    func confirmNumber(_ n: Int) {
        guard case let .needsNumber(uid) = provisionState, n >= 1 else { return }
        startBind(uid: uid, number: n)
    }

    /// «Отмена»: бросить текущий браслет — разоружить pending-write, отменить bind/автовозврат,
    /// вернуться в `waitingForChip`.
    func cancel() {
        resetChipState()
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
                    self.poolSize = tags.count
                    self.loaded = true
                }
            } catch {}
        }
    }

    /// UID «известен»: есть в пуле или записан в этой сессии (пул до refresh его не содержит; повтор
    /// с `number: null` сервер отдаёт как `200`).
    private func isKnown(_ uid: String) -> Bool {
        (poolUids?.contains(uid) ?? false) || freshFeed.contains { $0.uid == uid }
    }

    // MARK: - Обработка одного чтения

    /// Один прочитанный браслет. До первой эмиссии пула — игнор. `waitingForChip`/`failed` →
    /// маршрутизация по «известен»; `needsNumber` + другой UID → та же маршрутизация (тот же — игнор);
    /// `waitingForWrite` → сверка UID + исход записи; `binding`/`success` → игнор.
    func processReading(_ reading: TagReading) async {
        guard poolUids != nil else { return }
        switch provisionState {
        case .waitingForChip, .failed:
            route(uid: reading.uid)
        case let .needsNumber(uid):
            if reading.uid != uid { route(uid: reading.uid) }
        case let .waitingForWrite(uid, number):
            handleWriteTap(reading: reading, expectedUid: uid, number: number)
        case .binding, .success:
            break
        }
    }

    private func route(uid: String) {
        writeHint = nil
        if isKnown(uid) {
            startBind(uid: uid, number: nil)
        } else {
            provisionState = .needsNumber(uid: uid)
        }
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
                writeHint = "Приложите браслет ещё раз"
            } catch {
                provisionState = .failed(reason: "Неверный код от сервера")
                feedback.play(.failure)
            }
        case .error(let code) where code == 404 && requestedNumber == nil:
            // Сервер не знает UID (пул устарел) — просим номер.
            provisionState = .needsNumber(uid: uid)
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
        case .failed, .unsupported, .none:
            writeHint = "Не удалось записать, приложите снова"
            feedback.play(.failure)
        }
    }

    /// Запись подтверждена read-back'ом: лента (дедуп по UID — замена + наверх), автоинкремент номера,
    /// `success(number)`, разоружение сканера, фидбек + фанфары, возврат в `waitingForChip` после паузы.
    private func completeWrite(uid: String, number: Int) {
        freshFeed.removeAll { $0.uid == uid }
        freshFeed.insert(FreshBracelet(uid: uid, number: number), at: 0)
        if freshFeed.count > Self.feedCap {
            freshFeed.removeLast(freshFeed.count - Self.feedCap)
        }
        nextNumber = number == Int.max ? nil : number + 1
        provisionState = .success(number: number)
        writeHint = nil
        scanner?.clearPendingWrite()
        feedback.play(.success)
        feedback.fanfare()
        scheduleReturn()
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
