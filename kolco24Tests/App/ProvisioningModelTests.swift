//
//  ProvisioningModelTests.swift
//  kolco24Tests
//
//  Тесты `App/ProvisioningModel` (этап 10, двухтаповый провижининг) — Android-зеркала нет (логика
//  размазана по `ProvisioningScreen`/`AppContainer`), пишутся с нуля поверх РЕАЛЬНЫХ сторов над
//  `AppDatabase.makeInMemory()` + фейков только на платформенных границах (`FakeProvisioningScanner`,
//  фидбек-рекордер) + инжектированного `bindTag`-замыкания (управляемый `PostResult`).
//
//  Проверяем: happy path тап1→bind→pending-write→тап2→success + свежая пилюля; 409/404/403 → failed
//  с верной строкой; 401 → onUnauthorized (holder → loggedOut) + closeRequested; битый hex → «Неверный
//  код от сервера»; write-fail оставляет waitingForWrite (pending сохранён); свежая пилюля не даёт
//  двойного счёта после refresh легенды (max/subtract).
//

import Foundation
import Testing
@testable import kolco24

@MainActor
struct ProvisioningModelTests {

    // MARK: - Платформенные фейки

    /// Управляемый источник чтений + pending-write ячейка (провижининг). `emit` подаёт тап.
    final class FakeProvisioningScanner: ProvisioningScanning, @unchecked Sendable {
        private var continuation: AsyncStream<TagReading>.Continuation?
        private(set) var pendingUid: String?
        private(set) var pendingRecord: Data?
        private(set) var stopped = false
        func readings() -> AsyncStream<TagReading> { AsyncStream { cont in self.continuation = cont } }
        func start() {}
        func stop() { stopped = true; continuation?.finish() }
        func setPendingWrite(uid: String, record: Data) { pendingUid = uid; pendingRecord = record }
        func clearPendingWrite() { pendingUid = nil; pendingRecord = nil }
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

    /// Управляемый `bindTag` с логом вызовов.
    final class BindStub: @unchecked Sendable {
        var result: PostResult<TagBindResponse>
        private(set) var calls: [(Int, Int, String)] = []
        init(_ result: PostResult<TagBindResponse>) { self.result = result }
        func bind(_ raceId: Int, _ cpId: Int, _ uid: String) async -> PostResult<TagBindResponse> {
            calls.append((raceId, cpId, uid)); return result
        }
    }

    // MARK: - Фикстуры

    private let race = 7
    /// Валидный 16-байтовый код (32 hex-символа) — распаковывается `chipCodeFromHex` + `buildChipRecord`.
    private let goodCodeHex = String(repeating: "AB", count: 16)

    private func makeEnv() throws -> AppEnvironment {
        try AppEnvironment.inMemory(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "https://test.invalid")!,
                                     statusCode: 500, httpVersion: nil, headerFields: nil)!)
        })
    }

    private func seedCheckpoints(_ env: AppEnvironment, _ cps: [Checkpoint]) async throws {
        try await env.checkpointStore.replaceAllForRace(raceId: race, checkpoints: cps)
    }

    private func makeModel(
        env: AppEnvironment,
        bind: BindStub,
        onUnauthorized: @escaping () -> Void = {},
        feedback: RecordingFeedback = RecordingFeedback(),
        successHoldMs: Int = 60_000
    ) -> ProvisioningModel {
        ProvisioningModel(
            raceId: race,
            checkpointStore: env.checkpointStore,
            tagStore: env.tagStore,
            bindTag: bind.bind,
            onUnauthorized: onUnauthorized,
            feedback: feedback,
            successHoldMs: successHoldMs
        )
    }

    private func reading(uid: String, writeResult: ChipWriteResult? = nil, wall: Int64 = 2000) -> TagReading {
        TagReading(code: nil, uid: uid,
                   sample: TimeSample(wallMs: wall, elapsedMs: 1000, trustedMs: nil, bootCount: nil),
                   writeResult: writeResult)
    }

    private func okResponse(number: Int = 5, code: String) -> PostResult<TagBindResponse> {
        .success(TagBindResponse(bid: "b1", checkpointId: 1, number: number, nfcUid: "U1", code: code))
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()) {
            if clock.now > deadline { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func kp(_ id: Int, number: Int, color: String = "red") -> Checkpoint {
        Checkpoint(id: id, raceId: race, number: number, cost: 4, type: "kp", description: nil, color: color)
    }

    // MARK: - Happy path

    @Test func happyPath_tap1Bind_pendingWrite_tap2Success() async throws {
        let env = try makeEnv()
        try await seedCheckpoints(env, [kp(1, number: 5)])
        let feedback = RecordingFeedback()
        let bind = BindStub(okResponse(number: 5, code: goodCodeHex))
        let model = makeModel(env: env, bind: bind, feedback: feedback)
        let scanner = FakeProvisioningScanner()
        model.start(scanner: scanner)
        await waitUntil { !model.checkpoints.isEmpty }

        // Тап 1: UID → bind → waitingForWrite, сканер вооружён pending-write.
        scanner.emit(reading(uid: "U1"))
        await waitUntil { if case .waitingForWrite = model.provisionState { return true }; return false }
        guard case let .waitingForWrite(uid, code) = model.provisionState else {
            Issue.record("ожидался waitingForWrite, получено \(model.provisionState)"); return
        }
        #expect(uid == "U1")
        #expect(code == goodCodeHex)
        #expect(bind.calls.count == 1)
        #expect(bind.calls.first?.1 == 1) // checkpoint.id
        #expect(scanner.pendingUid == "U1")
        #expect(scanner.pendingRecord != nil)

        // Тап 2: тот же UID + успешная запись → success(number) + свежая пилюля + фанфары.
        scanner.emit(reading(uid: "U1", writeResult: .success))
        await waitUntil { if case .success = model.provisionState { return true }; return false }
        #expect(model.provisionState == .success(number: 5))
        #expect(model.freshLabels(model.checkpoints[0]).count == 1)
        #expect(feedback.successCount == 1)
        #expect(feedback.fanfares == 1)
        #expect(scanner.pendingUid == nil) // разоружён после успеха
    }

    // MARK: - Ошибки bind

    @Test func bind409_failedConflictString() async throws {
        try await assertBindFailure(result: .conflict, expected: "Этот тег уже привязан к другому КП")
    }

    @Test func bind404_failedNotFoundString() async throws {
        try await assertBindFailure(result: .error(code: 404), expected: "КП не найдено")
    }

    @Test func bind403_failedForbiddenString() async throws {
        try await assertBindFailure(
            result: .forbidden, expected: "Нет прав администратора этой гонки или ошибка подписи/часов")
    }

    private func assertBindFailure(result: PostResult<TagBindResponse>, expected: String) async throws {
        let env = try makeEnv()
        try await seedCheckpoints(env, [kp(1, number: 5)])
        let feedback = RecordingFeedback()
        let model = makeModel(env: env, bind: BindStub(result), feedback: feedback)
        let scanner = FakeProvisioningScanner()
        model.start(scanner: scanner)
        await waitUntil { !model.checkpoints.isEmpty }

        scanner.emit(reading(uid: "U1"))
        await waitUntil { if case .failed = model.provisionState { return true }; return false }
        #expect(model.provisionState == .failed(reason: expected))
        #expect(scanner.pendingUid == nil) // запись не вооружена
        #expect(feedback.failureCount == 1)
    }

    // MARK: - 401 → onUnauthorized

    @Test func bind401_callsOnUnauthorized_holderLoggedOut_andRequestsClose() async throws {
        let env = try makeEnv()
        try await seedCheckpoints(env, [kp(1, number: 5)])
        env.adminSessionHolder.set(.loggedIn(email: "a@b.ru", token: "tok", expiresAt: "2999-01-01T00:00:00Z"))
        let repo = env.adminAuthRepository
        let model = makeModel(env: env, bind: BindStub(.unauthorized),
                              onUnauthorized: { repo.onUnauthorized() })
        let scanner = FakeProvisioningScanner()
        model.start(scanner: scanner)
        await waitUntil { !model.checkpoints.isEmpty }

        scanner.emit(reading(uid: "U1"))
        await waitUntil { model.closeRequested }
        #expect(model.closeRequested)
        #expect(env.adminSessionHolder.session == .loggedOut)
    }

    // MARK: - Битый hex

    @Test func bindSuccessWithBadHex_failedInvalidCodeString() async throws {
        let env = try makeEnv()
        try await seedCheckpoints(env, [kp(1, number: 5)])
        let model = makeModel(env: env, bind: BindStub(okResponse(code: "ZZ-not-hex")))
        let scanner = FakeProvisioningScanner()
        model.start(scanner: scanner)
        await waitUntil { !model.checkpoints.isEmpty }

        scanner.emit(reading(uid: "U1"))
        await waitUntil { if case .failed = model.provisionState { return true }; return false }
        #expect(model.provisionState == .failed(reason: "Неверный код от сервера"))
        #expect(scanner.pendingUid == nil)
    }

    // MARK: - Ошибка записи (тап 2) оставляет waitingForWrite

    @Test func writeFailure_staysWaitingForWrite_pendingKept() async throws {
        let env = try makeEnv()
        try await seedCheckpoints(env, [kp(1, number: 5)])
        let feedback = RecordingFeedback()
        let model = makeModel(env: env, bind: BindStub(okResponse(code: goodCodeHex)), feedback: feedback)
        let scanner = FakeProvisioningScanner()
        model.start(scanner: scanner)
        await waitUntil { !model.checkpoints.isEmpty }

        scanner.emit(reading(uid: "U1"))
        await waitUntil { if case .waitingForWrite = model.provisionState { return true }; return false }

        // Тап 2 с неудачной записью → остаёмся в waitingForWrite, pending-write НЕ разоружён.
        scanner.emit(reading(uid: "U1", writeResult: .failed(message: "NAK")))
        await waitUntil { model.writeHint == "Не удалось записать, приложите снова" }
        if case .waitingForWrite = model.provisionState {} else {
            Issue.record("ожидался waitingForWrite после write-fail, получено \(model.provisionState)")
        }
        #expect(scanner.pendingUid == "U1") // повтор безопасен, запись сохранена
        #expect(model.freshLabels(model.checkpoints[0]).isEmpty)

        // Чужой чип на тапе 2 → «Приложите тот же чип», без записи.
        scanner.emit(reading(uid: "OTHER", writeResult: nil))
        await waitUntil { model.writeHint == "Приложите тот же чип" }
        if case .waitingForWrite = model.provisionState {} else {
            Issue.record("ожидался waitingForWrite после чужого чипа")
        }
    }

    // MARK: - Свежая пилюля не задваивается после refresh легенды

    @Test func freshPill_noDoubleCount_afterLegendRefresh() async throws {
        let env = try makeEnv()
        try await seedCheckpoints(env, [kp(1, number: 5)])
        // Стартовый кэш: 1 привязанный тег на КП.
        try await env.tagStore.replaceAllForRace(raceId: race, tags: [
            kolco24.Tag(raceId: race, bid: "old", checkpointId: 1, checkMethod: "nfc")
        ])
        let model = makeModel(env: env, bind: BindStub(okResponse(code: goodCodeHex)))
        let scanner = FakeProvisioningScanner()
        model.start(scanner: scanner)
        await waitUntil { !model.checkpoints.isEmpty }
        let cp = model.checkpoints[0]
        await waitUntil { model.alreadyBound(cp) == 1 } // кэш осел
        #expect(model.alreadyBound(cp) == 1)

        // Записываем свежий чип (тап1 → тап2 success).
        scanner.emit(reading(uid: "U1"))
        await waitUntil { if case .waitingForWrite = model.provisionState { return true }; return false }
        scanner.emit(reading(uid: "U1", writeResult: .success))
        await waitUntil { if case .success = model.provisionState { return true }; return false }
        // Свежий вычитается из кэша: alreadyBound 1 → 0, пилюля одна.
        await waitUntil { model.alreadyBound(cp) == 0 }
        #expect(model.freshLabels(cp).count == 1)

        // Mid-session refresh легенды доставляет свежий тег в кэш (cached 1 → 2).
        try await env.tagStore.replaceAllForRace(raceId: race, tags: [
            kolco24.Tag(raceId: race, bid: "old", checkpointId: 1, checkMethod: "nfc"),
            kolco24.Tag(raceId: race, bid: "new", checkpointId: 1, checkMethod: "nfc"),
        ])
        await waitUntil { model.alreadyBound(cp) == 1 }
        // Итог отображения: «Уже привязано: 1» + 1 свежая пилюля = 2 (не 3 — без двойного счёта).
        #expect(model.alreadyBound(cp) == 1)
        #expect(model.freshLabels(cp).count == 1)
    }

    // MARK: - Смена КП сбрасывает pending-write

    @Test func selectCheckpoint_resetsPendingWriteAndState() async throws {
        let env = try makeEnv()
        try await seedCheckpoints(env, [kp(1, number: 5), kp(2, number: 12, color: "blue")])
        let model = makeModel(env: env, bind: BindStub(okResponse(code: goodCodeHex)))
        let scanner = FakeProvisioningScanner()
        model.start(scanner: scanner)
        await waitUntil { model.checkpoints.count == 2 }

        scanner.emit(reading(uid: "U1"))
        await waitUntil { if case .waitingForWrite = model.provisionState { return true }; return false }
        #expect(scanner.pendingUid == "U1")

        model.selectCheckpoint(index: 1)
        #expect(model.selectedIndex == 1)
        #expect(model.provisionState == .waitingForChip)
        #expect(scanner.pendingUid == nil)
    }
}
