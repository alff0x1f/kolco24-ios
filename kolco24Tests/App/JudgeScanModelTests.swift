//
//  JudgeScanModelTests.swift
//  kolco24Tests
//
//  Тесты `App/JudgeScanModel` (этап 10) — Android-зеркала нет (логика размазана по `MainActivity`/
//  `JudgeScanScreen`), пишутся с нуля поверх РЕАЛЬНОГО `JudgeScanStore`/`MemberTagStore` над
//  `AppDatabase.makeInMemory()` + фейков только на платформенных границах (`FakeChipScanner`,
//  фидбек-рекордер) + `FakeTransport` для инлайн-refresh пула.
//
//  Проверяем: `recorded` пишет строку с полями сэмпла и триггерит upload (POST по логу транспорта);
//  `kpChip`/`unknownChip` не пишут; `poolNotReady` при пустом несинхронизированном пуле поднимает
//  `needsSync` и делает инлайн-`refreshMemberTags` (GET по логу); лента капится 20; `stop` отменяет
//  drain-цикл.
//

import Foundation
import Testing
@testable import kolco24

@MainActor
struct JudgeScanModelTests {

    // MARK: - Платформенные фейки

    /// Управляемый источник чтений (зеркало `ScanModelTests.FakeChipScanner`).
    final class FakeChipScanner: ChipScanning, @unchecked Sendable {
        private var continuation: AsyncStream<TagReading>.Continuation?
        private(set) var started = false
        private(set) var stopped = false
        func readings() -> AsyncStream<TagReading> {
            AsyncStream { cont in self.continuation = cont }
        }
        func start() { started = true }
        func stop() { stopped = true; continuation?.finish() }
        func emit(_ reading: TagReading) { continuation?.yield(reading) }
        func finish() { continuation?.finish() }
    }

    /// Рекордер фидбека.
    final class RecordingFeedback: ScanFeedbackPlaying, @unchecked Sendable {
        private(set) var plays: [ScanFeedbackKind] = []
        private(set) var fanfares = 0
        func play(_ kind: ScanFeedbackKind) { plays.append(kind) }
        func fanfare() { fanfares += 1 }
        var successCount: Int { plays.filter { if case .success = $0 { return true }; return false }.count }
        var failureCount: Int { plays.filter { if case .failure = $0 { return true }; return false }.count }
    }

    /// Детерминированный генератор id судейской строки.
    final class IdGen: @unchecked Sendable {
        private var n = 0
        func next() -> String { n += 1; return "js-\(n)" }
    }

    // MARK: - Фикстуры

    private let race = 7

    private func makeEnv(transport: FakeTransport = FakeTransport()) throws -> AppEnvironment {
        try AppEnvironment.inMemory(transport: transport.handle)
    }

    private func makeModel(
        env: AppEnvironment,
        eventType: String = "start",
        feedback: RecordingFeedback = RecordingFeedback(),
        idGen: IdGen = IdGen(),
        drainIntervalMs: Int = 100_000
    ) -> JudgeScanModel {
        JudgeScanModel(
            raceId: race,
            eventType: eventType,
            judgeScanStore: env.judgeScanStore,
            repository: env.judgeScanUploadRepository,
            memberTagsRepository: env.memberTagsRepository,
            feedback: feedback,
            installId: env.installId,
            newScanId: idGen.next,
            drainIntervalMs: drainIntervalMs
        )
    }

    private func reading(code: Data?, uid: String, elapsed: Int64 = 1000, wall: Int64 = 2000) -> TagReading {
        TagReading(
            code: code, uid: uid,
            sample: TimeSample(wallMs: wall, elapsedMs: elapsed, trustedMs: nil, bootCount: nil)
        )
    }

    private func kpCode(_ seed: UInt8) -> Data { Data((0..<16).map { UInt8(($0 + Int(seed)) & 0xFF) }) }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()) {
            if clock.now > deadline { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func acceptedBody(_ ids: [String]) -> String {
        "{\"accepted\":[\(ids.map { "\"\($0)\"" }.joined(separator: ","))]}"
    }

    /// Есть ли в логе транспорта POST на путь `judge_scans`.
    private func hasJudgePost(_ transport: FakeTransport) -> Bool {
        transport.recorded.contains {
            ($0.httpMethod == "POST") && ($0.url?.path.contains("judge_scans") ?? false)
        }
    }

    /// Есть ли в логе транспорта GET на путь `member_tags`.
    private func hasMemberTagsGet(_ transport: FakeTransport) -> Bool {
        transport.recorded.contains {
            ($0.httpMethod ?? "GET") == "GET" && ($0.url?.path.contains("member_tags") ?? false)
        }
    }

    // MARK: - recorded пишет строку + триггерит upload

    @Test func recorded_writesRowWithSampleFieldsAndTriggersUpload() async throws {
        let transport = FakeTransport()
        let env = try makeEnv(transport: transport)
        // Пул синхронизирован: браслет uid "AA" → участник 42.
        try await env.memberTagStore.insertAll([MemberTag(raceId: race, nfcUid: "AA", number: 42)])
        // Upload-попытки фейлятся (офлайн) → флаги остаются 0, строку можно прочитать через unuploadedLocal.
        transport.enqueueError(URLError(.notConnectedToInternet)) // judge local POST
        transport.enqueueError(URLError(.notConnectedToInternet)) // judge cloud POST

        let feedback = RecordingFeedback()
        let model = makeModel(env: env, eventType: "finish", feedback: feedback)
        let scanner = FakeChipScanner()
        model.start(scanner: scanner)
        await waitUntil { model.poolLoaded }

        scanner.emit(reading(code: nil, uid: "AA", elapsed: 1000, wall: 2000))

        // Строка записана.
        await waitUntil { (try? await env.judgeScanStore.unuploadedLocal(raceId: race, limit: 10).count) == 1 }
        let rows = try await env.judgeScanStore.unuploadedLocal(raceId: race, limit: 10)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.id == "js-1")
        #expect(row.eventType == "finish")
        #expect(row.participantNumber == 42)
        #expect(row.nfcUid == "AA")
        #expect(row.takenAt == 2000)             // sample.wallMs
        #expect(row.elapsedRealtimeAt == 1000)   // sample.elapsedMs
        #expect(row.trustedTakenAt == nil)
        #expect(row.bootCount == nil)
        #expect(row.sourceInstallId == "install-test")

        // Upload триггернут (POST по логу транспорта).
        await waitUntil { hasJudgePost(transport) }
        #expect(hasJudgePost(transport))
        // Успешный recorded → success-фидбек.
        #expect(feedback.successCount == 1)
        // Лента получила запись.
        #expect(model.feed.count == 1)
        #expect(model.needsSync == false)
    }

    // MARK: - kpChip / unknownChip не пишут

    @Test func kpChipAndUnknown_doNotWrite() async throws {
        let transport = FakeTransport()
        let env = try makeEnv(transport: transport)
        // Пул непуст (синхронизирован), но uid'ы сканов в нём отсутствуют.
        try await env.memberTagStore.insertAll([MemberTag(raceId: race, nfcUid: "AA", number: 42)])

        let feedback = RecordingFeedback()
        let model = makeModel(env: env, feedback: feedback)
        let scanner = FakeChipScanner()
        model.start(scanner: scanner)
        await waitUntil { model.poolLoaded }

        // KP-чип: uid не в пуле, но есть K24-код → kpChip.
        scanner.emit(reading(code: kpCode(1), uid: "BB"))
        // Неизвестный чип: uid не в пуле, кода нет → unknownChip.
        scanner.emit(reading(code: nil, uid: "CC"))

        await waitUntil { model.feed.count == 2 }
        #expect(model.feed.count == 2)
        // Ни одной судейской строки не записано.
        let pending = try await env.judgeScanStore.pendingUploadRaces()
        #expect(pending.isEmpty)
        // Никакого POST на judge_scans.
        #expect(hasJudgePost(transport) == false)
        // Оба — failure-фидбек, ни одного success.
        #expect(feedback.failureCount == 2)
        #expect(feedback.successCount == 0)
    }

    // MARK: - poolNotReady + инлайн-refresh

    @Test func poolNotReady_onEmptyUnsyncedPool_triggersInlineRefresh() async throws {
        let transport = FakeTransport()
        let env = try makeEnv(transport: transport)
        // Пул пуст и никогда не синхронизировался. Инлайн-refresh фейлится (офлайн) → остаёмся poolNotReady.
        transport.enqueueError(URLError(.notConnectedToInternet)) // member_tags GET

        let feedback = RecordingFeedback()
        let model = makeModel(env: env, feedback: feedback)
        let scanner = FakeChipScanner()
        model.start(scanner: scanner)
        await waitUntil { model.poolLoaded }

        scanner.emit(reading(code: nil, uid: "AA"))

        await waitUntil { model.needsSync }
        #expect(model.needsSync)
        // Инлайн-refresh member_tags был сделан (GET по логу).
        #expect(hasMemberTagsGet(transport))
        // Строк не записано; в ленту poolNotReady не попадает.
        let pending = try await env.judgeScanStore.pendingUploadRaces()
        #expect(pending.isEmpty)
        #expect(model.feed.isEmpty)
    }

    // MARK: - Лента капится 20

    @Test func feed_capsAt20() async throws {
        let env = try makeEnv()
        // Пул непуст (синхронизирован) — чтобы сканы не упирались в poolNotReady.
        try await env.memberTagStore.insertAll([MemberTag(raceId: race, nfcUid: "SEED", number: 1)])

        let model = makeModel(env: env)
        let scanner = FakeChipScanner()
        model.start(scanner: scanner)
        await waitUntil { model.poolLoaded }

        // 25 неизвестных чипов (uid не в пуле, кода нет → unknownChip → идут в ленту).
        for i in 0..<25 {
            scanner.emit(reading(code: nil, uid: "U\(i)"))
        }

        // Ждём терминальный признак (последний скан U24 наверху ленты), а не только счётчик: при ожидании
        // по `count` предикат стал бы истинным на 20-м скане, пока U20..U24 ещё в буфере (флейки).
        await waitUntil {
            if case let .unknownChip(uid) = model.feed.first?.result { return uid == "U24" }
            return false
        }
        #expect(model.feed.count == JudgeScanModel.feedCap) // 20
        // Новые сверху: первый в ленте — последний просканированный (U24).
        if case let .unknownChip(uid) = model.feed.first?.result {
            #expect(uid == "U24")
        } else {
            Issue.record("ожидался unknownChip первым в ленте")
        }
    }

    // MARK: - stop отменяет drain-цикл

    @Test func stop_cancelsDrainLoop() async throws {
        let transport = FakeTransport()
        let env = try makeEnv(transport: transport)
        // Одна pending-строка, которую сервер «не принимает» (accepted:[]) → остаётся pending, каждый
        // проход цикла = 2 POST (local+cloud). Много ответов, чтобы очередь не опустела за тест.
        try await env.judgeScanStore.insert(JudgeScan(
            id: "seed", raceId: race, eventType: "start", participantNumber: 1, nfcUid: "AA",
            takenAt: 1000, elapsedRealtimeAt: 1000, sourceInstallId: "install-test"
        ))
        for _ in 0..<200 { transport.enqueue(statusCode: 200, bodyString: acceptedBody([])) }

        // Короткий интервал цикла — быстро набираем итерации.
        let model = makeModel(env: env, drainIntervalMs: 30)
        let scanner = FakeChipScanner()
        model.start(scanner: scanner)

        // Цикл прокрутился несколько раз (>2 POST → минимум пара итераций).
        await waitUntil { transport.callCount > 2 }
        #expect(transport.callCount > 2)

        model.stop()
        // После stop даём осесть финальному flush (2 POST) и любым in-flight.
        try? await Task.sleep(for: .milliseconds(120))
        let afterStop = transport.callCount
        // Ещё подождём — если цикл жив, счётчик бы рос.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(transport.callCount == afterStop)
    }
}
