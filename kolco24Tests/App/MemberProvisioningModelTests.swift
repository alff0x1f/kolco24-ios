//
//  MemberProvisioningModelTests.swift
//  kolco24Tests
//
//  Тесты `App/MemberProvisioningModel` (запись кода на браслет участника, iOS-first — Android-зеркала
//  нет). РЕАЛЬНЫЙ `MemberTagStore` над `AppDatabase.makeInMemory()` (пул сидится `insertAll`, как в
//  `ChipCheckModelTests`) + фейки только на платформенных границах (сканер с pending-write ячейкой,
//  фидбек-рекордер) + инжектированное `bindMemberTag`-замыкание (`MemberBindStub`).
//
//  Проверяем: оба режима (пул → `number: null`; не в пуле → ввод номера), 404-фолбэк, переходы
//  `needsNumber`, guard'ы `confirmNumber`/`cancel`, ошибки bind (409/401/битый hex), отбрасывание
//  позднего результата после `stop()`, тап 2 (чужой UID, write-fail), null-sentinel пула, тип записи
//  `0x2`, дедуп ленты.
//

import Foundation
import Testing
@testable import kolco24

@MainActor
struct MemberProvisioningModelTests {

    // MARK: - Платформенные фейки (копии вложенных из ProvisioningModelTests)

    /// Управляемый источник чтений + pending-write ячейка. `emit` подаёт тап.
    final class FakeProvisioningScanner: ProvisioningScanning, @unchecked Sendable {
        private var continuation: AsyncStream<TagReading>.Continuation?
        private(set) var pendingUid: String?
        private(set) var pendingRecord: Data?
        private(set) var clearCount = 0
        func readings() -> AsyncStream<TagReading> { AsyncStream { cont in self.continuation = cont } }
        func start() {}
        func stop() { continuation?.finish() }
        func setPendingWrite(uid: String, record: Data) { pendingUid = uid; pendingRecord = record }
        func clearPendingWrite() { pendingUid = nil; pendingRecord = nil; clearCount += 1 }
        func emit(_ reading: TagReading) { continuation?.yield(reading) }
    }

    final class RecordingFeedback: ScanFeedbackPlaying, @unchecked Sendable {
        private(set) var plays: [ScanFeedbackKind] = []
        private(set) var fanfares = 0
        func play(_ kind: ScanFeedbackKind) { plays.append(kind) }
        func fanfare() { fanfares += 1 }
        var successCount: Int { plays.filter { if case .success = $0 { return true }; return false }.count }
        var failureCount: Int { plays.filter { if case .failure = $0 { return true }; return false }.count }
    }

    /// Управляемый `bindMemberTag` с логом вызовов. `results` — очередь ответов (последний повторяется);
    /// `hold` — подвешивает вызов до `release()` (для «поздний результат после stop()»).
    final class MemberBindStub: @unchecked Sendable {
        var results: [PostResult<MemberTagBindResponse>]
        var hold = false
        private(set) var calls: [(raceId: Int, uid: String, number: Int?)] = []
        private var gate: CheckedContinuation<Void, Never>?
        var isHeld: Bool { gate != nil }
        init(_ results: PostResult<MemberTagBindResponse>...) { self.results = results }
        func bind(_ raceId: Int, _ uid: String, _ number: Int?) async -> PostResult<MemberTagBindResponse> {
            calls.append((raceId, uid, number))
            if hold { await withCheckedContinuation { gate = $0 } }
            return results.count > 1 ? results.removeFirst() : results[0]
        }
        func release() { let g = gate; gate = nil; g?.resume() }
    }

    // MARK: - Фикстуры

    private let race = 7
    private let goodCodeHex = String(repeating: "AB", count: 16)

    private func makeEnv() throws -> AppEnvironment {
        try AppEnvironment.inMemory(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "https://test.invalid")!,
                                     statusCode: 500, httpVersion: nil, headerFields: nil)!)
        })
    }

    private func makeModel(
        env: AppEnvironment,
        bind: MemberBindStub,
        onUnauthorized: @escaping () -> Void = {},
        feedback: RecordingFeedback = RecordingFeedback(),
        successHoldMs: Int = 60_000
    ) -> MemberProvisioningModel {
        MemberProvisioningModel(
            raceId: race,
            memberTagStore: env.memberTagStore,
            bindMemberTag: bind.bind,
            onUnauthorized: onUnauthorized,
            feedback: feedback,
            successHoldMs: successHoldMs
        )
    }

    /// Модель + запущенный сканер, пул осел (`loaded`).
    private func started(
        env: AppEnvironment, bind: MemberBindStub,
        onUnauthorized: @escaping () -> Void = {},
        feedback: RecordingFeedback = RecordingFeedback(),
        successHoldMs: Int = 60_000
    ) async -> (MemberProvisioningModel, FakeProvisioningScanner) {
        let model = makeModel(env: env, bind: bind, onUnauthorized: onUnauthorized,
                              feedback: feedback, successHoldMs: successHoldMs)
        let scanner = FakeProvisioningScanner()
        model.start(scanner: scanner)
        await waitUntil { model.loaded }
        return (model, scanner)
    }

    private func seedPool(_ env: AppEnvironment, _ tags: [(String, Int)]) async throws {
        try await env.memberTagStore.insertAll(tags.map { MemberTag(raceId: race, nfcUid: $0.0, number: $0.1) })
    }

    private func reading(uid: String, writeResult: ChipWriteResult? = nil) -> TagReading {
        TagReading(code: nil, uid: uid,
                   sample: TimeSample(wallMs: 2000, elapsedMs: 1000, trustedMs: nil, bootCount: nil),
                   writeResult: writeResult)
    }

    private func ok(number: Int, uid: String = "U1", code: String? = nil) -> PostResult<MemberTagBindResponse> {
        .success(MemberTagBindResponse(number: number, nfcUid: uid, code: code ?? goodCodeHex))
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()) {
            if clock.now > deadline { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func isWaitingForWrite(_ m: MemberProvisioningModel) -> Bool {
        if case .waitingForWrite = m.provisionState { return true }; return false
    }
    private func isNeedsNumber(_ m: MemberProvisioningModel) -> Bool {
        if case .needsNumber = m.provisionState { return true }; return false
    }
    private func isSuccess(_ m: MemberProvisioningModel) -> Bool {
        if case .success = m.provisionState { return true }; return false
    }
    private func isFailed(_ m: MemberProvisioningModel) -> Bool {
        if case .failed = m.provisionState { return true }; return false
    }

    /// Полный цикл тап1 → bind → тап2 success для [uid].
    private func writeBracelet(_ model: MemberProvisioningModel, _ scanner: FakeProvisioningScanner,
                               uid: String) async {
        scanner.emit(reading(uid: uid))
        await waitUntil { isWaitingForWrite(model) }
        scanner.emit(reading(uid: uid, writeResult: .success))
        await waitUntil { isSuccess(model) }
    }

    // MARK: - Режим «пул»

    @Test func pooledUid_bindsWithNilNumber_writes_success_thenReturnsToWaiting() async throws {
        let env = try makeEnv()
        try await seedPool(env, [("U1", 101)])
        let feedback = RecordingFeedback()
        let bind = MemberBindStub(ok(number: 101))
        let (model, scanner) = await started(env: env, bind: bind, feedback: feedback, successHoldMs: 50)

        scanner.emit(reading(uid: "U1"))
        await waitUntil { isWaitingForWrite(model) }
        #expect(model.provisionState == .waitingForWrite(uid: "U1", number: 101))
        #expect(bind.calls.count == 1)
        #expect(bind.calls.first?.raceId == race)
        #expect(bind.calls.first?.uid == "U1")
        #expect(bind.calls.first?.number == nil)
        #expect(scanner.pendingUid == "U1")

        scanner.emit(reading(uid: "U1", writeResult: .success))
        await waitUntil { isSuccess(model) }
        #expect(model.provisionState == .success(number: 101))
        #expect(scanner.pendingUid == nil)
        #expect(model.nextNumber == 102)
        #expect(model.freshFeed == [.init(uid: "U1", number: 101)])
        #expect(feedback.successCount == 1)
        #expect(feedback.fanfares == 1)

        await waitUntil { model.provisionState == .waitingForChip }
        #expect(model.provisionState == .waitingForChip)
    }

    @Test func pendingRecord_isParticipantType() async throws {
        let env = try makeEnv()
        try await seedPool(env, [("U1", 101)])
        let (model, scanner) = await started(env: env, bind: MemberBindStub(ok(number: 101)))

        scanner.emit(reading(uid: "U1"))
        await waitUntil { isWaitingForWrite(model) }
        let record = try #require(scanner.pendingRecord)
        #expect(Int([UInt8](record)[3] & 0x0F) == CHIP_TYPE_PARTICIPANT)
        #expect(parseChipRecord(pages: record, type: CHIP_TYPE_PARTICIPANT) == (try chipCodeFromHex(goodCodeHex)))
        #expect(parseChipRecord(pages: record) == nil) // не KP
    }

    // MARK: - Режим «ввод номера»

    @Test func unknownUid_needsNumber_confirm_bindsWithNumber() async throws {
        let env = try makeEnv()
        try await seedPool(env, [("OTHER", 1)])
        let bind = MemberBindStub(ok(number: 7))
        let (model, scanner) = await started(env: env, bind: bind)

        scanner.emit(reading(uid: "U1"))
        await waitUntil { isNeedsNumber(model) }
        #expect(model.provisionState == .needsNumber(uid: "U1"))
        #expect(bind.calls.isEmpty)

        model.confirmNumber(7)
        await waitUntil { isWaitingForWrite(model) }
        #expect(bind.calls.count == 1)
        #expect(bind.calls.first?.number == 7)
        #expect(model.provisionState == .waitingForWrite(uid: "U1", number: 7))
    }

    @Test func notFoundOnNil_goesToNeedsNumber() async throws {
        let env = try makeEnv()
        try await seedPool(env, [("U1", 101)])
        let feedback = RecordingFeedback()
        let bind = MemberBindStub(.error(code: 404))
        let (model, scanner) = await started(env: env, bind: bind, feedback: feedback)

        scanner.emit(reading(uid: "U1"))
        await waitUntil { isNeedsNumber(model) }
        #expect(model.provisionState == .needsNumber(uid: "U1"))
        #expect(bind.calls.first?.number == nil)
        #expect(feedback.failureCount == 0)
    }

    @Test func notFoundWithNumber_failedNotFoundString() async throws {
        let env = try makeEnv()
        try await seedPool(env, [])
        let bind = MemberBindStub(.error(code: 404))
        let (model, scanner) = await started(env: env, bind: bind)

        scanner.emit(reading(uid: "U1"))
        await waitUntil { isNeedsNumber(model) }
        model.confirmNumber(5)
        await waitUntil { isFailed(model) }
        #expect(model.provisionState == .failed(reason: "Не найдено на сервере"))
    }

    // MARK: - Переходы из needsNumber

    @Test func needsNumber_tapPooledUid_binds_sameUidIgnored() async throws {
        let env = try makeEnv()
        try await seedPool(env, [("P1", 101)])
        let bind = MemberBindStub(ok(number: 101, uid: "P1"))
        let (model, scanner) = await started(env: env, bind: bind)

        scanner.emit(reading(uid: "U1"))
        await waitUntil { isNeedsNumber(model) }
        // Тот же UID → игнор (остаёмся в needsNumber, без запроса).
        scanner.emit(reading(uid: "U1"))
        // Другой, пулный UID → bind с nil.
        scanner.emit(reading(uid: "P1"))
        await waitUntil { isWaitingForWrite(model) }
        #expect(bind.calls.count == 1)
        #expect(bind.calls.first?.uid == "P1")
        #expect(bind.calls.first?.number == nil)
    }

    @Test func needsNumber_sameUidTap_isIgnored() async throws {
        let env = try makeEnv()
        try await seedPool(env, [])
        let bind = MemberBindStub(ok(number: 1))
        let (model, _) = await started(env: env, bind: bind)

        await model.processReading(reading(uid: "U1"))
        #expect(model.provisionState == .needsNumber(uid: "U1"))
        await model.processReading(reading(uid: "U1"))
        #expect(model.provisionState == .needsNumber(uid: "U1"))
        #expect(bind.calls.isEmpty)
    }

    @Test func braceletWrittenThisSession_isKnown_bindsWithNil() async throws {
        let env = try makeEnv()
        try await seedPool(env, [])
        let bind = MemberBindStub(ok(number: 7))
        let (model, scanner) = await started(env: env, bind: bind)

        scanner.emit(reading(uid: "U1"))
        await waitUntil { isNeedsNumber(model) }
        model.confirmNumber(7)
        await waitUntil { isWaitingForWrite(model) }
        scanner.emit(reading(uid: "U1", writeResult: .success))
        await waitUntil { isSuccess(model) }
        model.cancel() // сброс в waitingForChip без ожидания hold

        // Повторный тап того же браслета: не в пуле, но записан в сессии → сразу bind(nil).
        scanner.emit(reading(uid: "U1"))
        await waitUntil { bind.calls.count == 2 }
        #expect(bind.calls.last?.number == nil)
        await waitUntil { isWaitingForWrite(model) }
        #expect(model.provisionState == .waitingForWrite(uid: "U1", number: 7))
    }

    // MARK: - Guard'ы confirmNumber / cancel

    @Test func confirmNumber_outsideNeedsNumber_orZero_isNoOp() async throws {
        let env = try makeEnv()
        try await seedPool(env, [])
        let bind = MemberBindStub(ok(number: 1))
        let (model, _) = await started(env: env, bind: bind)

        model.confirmNumber(5) // waitingForChip
        #expect(model.provisionState == .waitingForChip)

        await model.processReading(reading(uid: "U1"))
        #expect(model.provisionState == .needsNumber(uid: "U1"))
        model.confirmNumber(0)
        model.confirmNumber(-3)
        #expect(model.provisionState == .needsNumber(uid: "U1"))
        #expect(bind.calls.isEmpty)
    }

    @Test func cancel_fromWaitingForWrite_disarmsAndReturnsToWaiting() async throws {
        let env = try makeEnv()
        try await seedPool(env, [("U1", 101)])
        let (model, scanner) = await started(env: env, bind: MemberBindStub(ok(number: 101)))

        scanner.emit(reading(uid: "U1"))
        await waitUntil { isWaitingForWrite(model) }
        #expect(scanner.pendingUid == "U1")

        model.cancel()
        #expect(model.provisionState == .waitingForChip)
        #expect(model.writeHint == nil)
        #expect(scanner.pendingUid == nil)
    }

    // MARK: - Ошибки bind

    @Test func bind409_failedConflictString() async throws {
        let env = try makeEnv()
        try await seedPool(env, [("U1", 101)])
        let feedback = RecordingFeedback()
        let (model, scanner) = await started(env: env, bind: MemberBindStub(.conflict), feedback: feedback)

        scanner.emit(reading(uid: "U1"))
        await waitUntil { isFailed(model) }
        #expect(model.provisionState == .failed(reason: "Браслет уже привязан к другому участнику"))
        #expect(scanner.pendingUid == nil)
        #expect(feedback.failureCount == 1)
    }

    @Test func bind401_callsOnUnauthorized_andRequestsClose() async throws {
        let env = try makeEnv()
        try await seedPool(env, [("U1", 101)])
        env.adminSessionHolder.set(.loggedIn(email: "a@b.ru", token: "tok", expiresAt: "2999-01-01T00:00:00Z"))
        let repo = env.adminAuthRepository
        var unauthorizedCalls = 0
        let (model, scanner) = await started(env: env, bind: MemberBindStub(.unauthorized),
                                             onUnauthorized: { unauthorizedCalls += 1; repo.onUnauthorized() })

        scanner.emit(reading(uid: "U1"))
        await waitUntil { model.closeRequested }
        #expect(model.closeRequested)
        #expect(unauthorizedCalls == 1)
        #expect(env.adminSessionHolder.session == .loggedOut)
    }

    @Test func bindSuccessWithBadHex_failedInvalidCodeString() async throws {
        let env = try makeEnv()
        try await seedPool(env, [("U1", 101)])
        let (model, scanner) = await started(env: env, bind: MemberBindStub(ok(number: 101, code: "ZZ-not-hex")))

        scanner.emit(reading(uid: "U1"))
        await waitUntil { isFailed(model) }
        #expect(model.provisionState == .failed(reason: "Неверный код от сервера"))
        #expect(scanner.pendingUid == nil)
    }

    @Test func stopDuringBinding_lateResultDiscarded() async throws {
        let env = try makeEnv()
        try await seedPool(env, [("U1", 101)])
        let bind = MemberBindStub(ok(number: 101))
        bind.hold = true
        let (model, scanner) = await started(env: env, bind: bind)

        scanner.emit(reading(uid: "U1"))
        await waitUntil { bind.isHeld }
        #expect(model.provisionState == .binding(uid: "U1", number: nil))

        model.stop()
        bind.release()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.provisionState == .binding(uid: "U1", number: nil))
        #expect(scanner.pendingUid == nil)
    }

    // MARK: - Тап 2

    @Test func writeTap_foreignUid_hint_noSuccess() async throws {
        let env = try makeEnv()
        try await seedPool(env, [("U1", 101)])
        let (model, scanner) = await started(env: env, bind: MemberBindStub(ok(number: 101)))

        scanner.emit(reading(uid: "U1"))
        await waitUntil { isWaitingForWrite(model) }
        scanner.emit(reading(uid: "OTHER", writeResult: nil))
        await waitUntil { model.writeHint == "Приложите тот же браслет" }
        #expect(model.writeHint == "Приложите тот же браслет")
        #expect(model.provisionState == .waitingForWrite(uid: "U1", number: 101))
        #expect(scanner.pendingUid == "U1")
        #expect(model.freshFeed.isEmpty)
    }

    @Test func writeFailure_keepsPending_retrySucceeds() async throws {
        let env = try makeEnv()
        try await seedPool(env, [("U1", 101)])
        let (model, scanner) = await started(env: env, bind: MemberBindStub(ok(number: 101)))

        scanner.emit(reading(uid: "U1"))
        await waitUntil { isWaitingForWrite(model) }
        scanner.emit(reading(uid: "U1", writeResult: .failed(message: "NAK")))
        await waitUntil { model.writeHint == "Не удалось записать, приложите снова" }
        #expect(model.provisionState == .waitingForWrite(uid: "U1", number: 101))
        #expect(scanner.pendingUid == "U1")

        scanner.emit(reading(uid: "U1", writeResult: .success))
        await waitUntil { isSuccess(model) }
        #expect(model.provisionState == .success(number: 101))
        #expect(scanner.pendingUid == nil)
    }

    // MARK: - Пул и лента

    @Test func scanBeforePoolEmission_isIgnored() async throws {
        let env = try makeEnv()
        let bind = MemberBindStub(ok(number: 1))
        let model = makeModel(env: env, bind: bind)
        #expect(model.loaded == false)
        await model.processReading(reading(uid: "U1"))
        #expect(model.provisionState == .waitingForChip)
        #expect(bind.calls.isEmpty)
    }

    @Test func freshFeed_dedupsByUid_replacesAndMovesToTop() async throws {
        let env = try makeEnv()
        try await seedPool(env, [("A", 1), ("B", 2)])
        let bind = MemberBindStub(ok(number: 1, uid: "A"), ok(number: 2, uid: "B"), ok(number: 5, uid: "A"))
        let (model, scanner) = await started(env: env, bind: bind)

        await writeBracelet(model, scanner, uid: "A")
        model.cancel()
        await writeBracelet(model, scanner, uid: "B")
        model.cancel()
        #expect(model.freshFeed.map(\.uid) == ["B", "A"])

        await writeBracelet(model, scanner, uid: "A")
        #expect(model.freshFeed == [.init(uid: "A", number: 5), .init(uid: "B", number: 2)])
        #expect(model.nextNumber == 6)
    }
}
