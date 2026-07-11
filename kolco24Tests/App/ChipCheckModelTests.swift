//
//  ChipCheckModelTests.swift
//  kolco24Tests
//
//  Тесты `App/ChipCheckModel` + `App/MemberChipCheckModel` (этап 10) — Android-зеркала нет (логика
//  размазана по хостам), пишутся с нуля поверх РЕАЛЬНЫХ сторов над `AppDatabase.makeInMemory()` +
//  `FakeChipScanner` (платформенная граница) + фидбек-рекордера.
//
//  Проверяем: сканы до ПЕРВОЙ эмиссии легенды/пула игнорируются (null-sentinel); `ok`-классификация
//  КП-чипа по синхронизированной легенде; лента капится 20; браслет из пула → `ok`, вне пула → unknown.
//

import Foundation
import Testing
@testable import kolco24

@MainActor
struct ChipCheckModelTests {

    // MARK: - Платформенные фейки

    final class FakeChipScanner: ChipScanning, @unchecked Sendable {
        private var continuation: AsyncStream<TagReading>.Continuation?
        func readings() -> AsyncStream<TagReading> { AsyncStream { cont in self.continuation = cont } }
        func start() {}
        func stop() { continuation?.finish() }
        func emit(_ reading: TagReading) { continuation?.yield(reading) }
    }

    final class RecordingFeedback: ScanFeedbackPlaying, @unchecked Sendable {
        private(set) var plays: [ScanFeedbackKind] = []
        func play(_ kind: ScanFeedbackKind) { plays.append(kind) }
        func fanfare() {}
        var successCount: Int { plays.filter { if case .success = $0 { return true }; return false }.count }
        var failureCount: Int { plays.filter { if case .failure = $0 { return true }; return false }.count }
    }

    private let race = 7

    private func makeEnv() throws -> AppEnvironment {
        try AppEnvironment.inMemory(transport: { _ in
            (Data(), HTTPURLResponse(url: URL(string: "https://test.invalid")!,
                                     statusCode: 500, httpVersion: nil, headerFields: nil)!)
        })
    }

    private func reading(code: Data?, uid: String, wall: Int64 = 2000) -> TagReading {
        TagReading(code: code, uid: uid,
                   sample: TimeSample(wallMs: wall, elapsedMs: 1000, trustedMs: nil, bootCount: nil))
    }

    private func kpCode(_ seed: UInt8) -> Data { Data((0..<16).map { UInt8(($0 + Int(seed)) & 0xFF) }) }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()) {
            if clock.now > deadline { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - ChipCheckModel

    @Test func chipCheck_ignoresScansBeforeLegendEmission() async throws {
        let env = try makeEnv()
        let model = ChipCheckModel(raceId: race, tagStore: env.tagStore,
                                   checkpointStore: env.checkpointStore, feedback: RecordingFeedback())
        // Сразу после init observation-Task ещё не выполнялся (нет точки приостановки) — легенда неизвестна.
        #expect(model.loaded == false)
        // Прямой вызов обработчика: null-sentinel → чтение игнорируется, лента пуста.
        await model.processReading(reading(code: nil, uid: "XX"))
        #expect(model.feed.isEmpty)
        #expect(model.lastResult == nil)
    }

    @Test func chipCheck_okForBoundChip() async throws {
        let env = try makeEnv()
        let code = kpCode(3)
        let bid = LegendCrypto.bid(code: code)
        try await env.checkpointStore.replaceAllForRace(raceId: race, checkpoints: [
            Checkpoint(id: 10, raceId: race, number: 7, cost: 8, type: "kp", description: nil, color: "red")
        ])
        try await env.tagStore.replaceAllForRace(raceId: race, tags: [
            kolco24.Tag(raceId: race, bid: bid, checkpointId: 10, checkMethod: "nfc")
        ])

        let feedback = RecordingFeedback()
        let model = ChipCheckModel(raceId: race, tagStore: env.tagStore,
                                   checkpointStore: env.checkpointStore, feedback: feedback)
        let scanner = FakeChipScanner()
        model.start(scanner: scanner)
        await waitUntil { model.loaded }

        // КП-подписка — отдельный observation, который мог ещё не осесть к моменту `loaded` (его
        // выставляет только tag-подписка). Модель переклассифицирует на каждом чтении, поэтому шлём чип
        // повторно, пока не получим `.ok` — детерминированно, без фиксированного sleep.
        await waitUntil {
            scanner.emit(reading(code: code, uid: "0411223344AABB"))
            if case .ok = model.lastResult { return true }; return false
        }
        guard case let .ok(uid, number, cost, color, resultBid, checkMethod, chipsOnKp) = model.lastResult else {
            Issue.record("ожидался .ok, получено \(String(describing: model.lastResult))"); return
        }
        #expect(uid == "0411223344AABB")
        #expect(number == 7)
        #expect(cost == 8)
        #expect(color == .red)
        #expect(resultBid == bid)
        #expect(checkMethod == "nfc")
        #expect(chipsOnKp == 1)
        #expect(feedback.successCount == 1)
    }

    @Test func chipCheck_feedCapsAt20() async throws {
        let env = try makeEnv()
        let model = ChipCheckModel(raceId: race, tagStore: env.tagStore,
                                   checkpointStore: env.checkpointStore, feedback: RecordingFeedback())
        let scanner = FakeChipScanner()
        model.start(scanner: scanner)
        await waitUntil { model.loaded } // легенда пуста → каждый скан = noCode → идёт в ленту

        for i in 0..<25 { scanner.emit(reading(code: nil, uid: "U\(i)")) }

        // Ждём терминальный признак (последний скан наверху ленты), а не только счётчик: при ожидании
        // по `count` предикат мог бы стать истинным на 20-м скане, пока U20..U24 ещё в буфере (флейки).
        await waitUntil { model.feed.first?.result.uid == "U24" }
        #expect(model.feed.first?.result.uid == "U24") // новые сверху
        #expect(model.feed.count == ChipCheckModel.feedCap) // 20
    }

    // MARK: - MemberChipCheckModel

    @Test func memberCheck_ignoresScansBeforePoolEmission() async throws {
        let env = try makeEnv()
        let model = MemberChipCheckModel(raceId: race, memberTagStore: env.memberTagStore,
                                         feedback: RecordingFeedback())
        #expect(model.loaded == false)
        await model.processReading(reading(code: nil, uid: "XX"))
        #expect(model.feed.isEmpty)
        #expect(model.lastResult == nil)
    }

    @Test func memberCheck_okForPooledBraceletAndUnknownOtherwise() async throws {
        let env = try makeEnv()
        try await env.memberTagStore.insertAll([MemberTag(raceId: race, nfcUid: "W1", number: 101)])

        let feedback = RecordingFeedback()
        let model = MemberChipCheckModel(raceId: race, memberTagStore: env.memberTagStore, feedback: feedback)
        let scanner = FakeChipScanner()
        model.start(scanner: scanner)
        await waitUntil { model.loaded }
        #expect(model.poolSize == 1)

        // Пулный браслет → ok(101).
        scanner.emit(reading(code: nil, uid: "W1"))
        await waitUntil { if case .ok = model.lastResult { return true }; return false }
        #expect(model.lastResult == .ok(uid: "W1", number: 101))

        // Вне пула, кода нет → unknown.
        scanner.emit(reading(code: nil, uid: "ZZ"))
        await waitUntil { if case .unknown = model.lastResult { return true }; return false }
        #expect(model.lastResult == .unknown(uid: "ZZ"))

        #expect(feedback.successCount == 1)
        #expect(feedback.failureCount == 1)
    }

    @Test func memberCheck_feedCapsAt20() async throws {
        let env = try makeEnv()
        try await env.memberTagStore.insertAll([MemberTag(raceId: race, nfcUid: "SEED", number: 1)])
        let model = MemberChipCheckModel(raceId: race, memberTagStore: env.memberTagStore,
                                         feedback: RecordingFeedback())
        let scanner = FakeChipScanner()
        model.start(scanner: scanner)
        await waitUntil { model.loaded }

        for i in 0..<25 { scanner.emit(reading(code: nil, uid: "U\(i)")) }

        // Терминальный признак (последний скан наверху), не только счётчик — иначе флейки под нагрузкой.
        await waitUntil { model.feed.first?.result.uid == "U24" }
        #expect(model.feed.first?.result.uid == "U24")
        #expect(model.feed.count == MemberChipCheckModel.feedCap)
    }
}
