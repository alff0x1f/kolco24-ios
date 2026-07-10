//
//  TrackUploadRepositoryTests.swift
//  kolco24Tests
//
//  Поведенческая спека дренажа выгрузки трека — зеркало upload-части `data/track/TrackRepositoryTest.kt`
//  поверх РЕАЛЬНОГО `TrackStore` над `AppDatabase.makeInMemory()` + `FakeTransport` (конвенция
//  этапов 2–7). Структурный клон `MarkUploadRepositoryTests` без frame-/version-guard-кейсов (точки
//  иммутабельны).
//
//  **Ловушка `FakeTransport`:** FIFO-очередь ответов по порядку ВЫЗОВОВ (не роутинг по URL); граф
//  даёт cloud и local ОДИН транспорт — ответы энкьюятся в порядке `flushScope` (сначала Local, затем
//  Cloud; при нескольких скоупах — в порядке `pendingUploadScopes()`). Многие тесты ставят
//  `uploadedCloud = 1`, чтобы cloud-дренаж был пуст (returns nil, без транспорта) и оставить фокус на Local.
//

import Foundation
import Testing
import GRDB
@testable import kolco24

struct TrackUploadRepositoryTests {

    // MARK: - Фикстуры

    private func makePoint(
        id: String,
        raceId: Int = 7,
        teamId: Int = 42,
        segmentId: String = "seg-1",
        order: Int64 = 0,
        uploadedLocal: Bool = false,
        uploadedCloud: Bool = false
    ) -> TrackPoint {
        TrackPoint(
            id: id,
            raceId: raceId,
            teamId: teamId,
            lat: 55.75,
            lon: 37.61,
            accuracy: 12.4,
            altitude: nil,
            verticalAccuracyMeters: nil,
            gpsTimeMs: 1_000 + order,
            elapsedRealtimeAt: 1_000 + order,
            bootCount: nil,
            wallMs: 1_000 + order,
            trustedMs: nil,
            segmentId: segmentId,
            uploadedLocal: uploadedLocal,
            uploadedCloud: uploadedCloud
        )
    }

    private func makeClient(
        base: String,
        transport: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) -> ApiClient {
        ApiClient(
            baseURL: base,
            keyId: "ios-v1",
            secret: "test-secret-123",
            installId: "install-abc",
            appVersion: "2.0.1",
            nowSeconds: { 1_700_000_000 },
            elapsedNowMs: { 0 },
            transport: transport
        )
    }

    private func makeRepo(
        wallNow: @escaping () -> Int64 = { 5000 }
    ) throws -> (repo: TrackUploadRepository, store: TrackStore, transport: FakeTransport, db: AppDatabase) {
        let db = try AppDatabase.makeInMemory()
        let store = TrackStore(db.writer)
        let transport = FakeTransport()
        let cloud = makeClient(base: "https://cloud.test", transport: transport.handle)
        let local = makeClient(base: "http://local.test", transport: transport.handle)
        let repo = TrackUploadRepository(trackStore: store, cloud: cloud, local: local, wallNow: wallNow)
        return (repo, store, transport, db)
    }

    private func acceptedBody(_ ids: [String]) -> String {
        let joined = ids.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"accepted\":[\(joined)]}"
    }

    // MARK: - marksPerTargetIndependently (обе цели → флаги независимо)

    @Test func uploadPending_marksPerTargetIndependently() async throws {
        let (repo, store, transport, _) = try makeRepo()
        try await store.insertAll([makePoint(id: "p1")])
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["p1"])) // Local
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["p1"])) // Cloud

        await repo.uploadPending(raceId: 7, teamId: 42)

        let scopes = try await store.pendingUploadScopes()
        #expect(scopes.isEmpty) // ни одной pending точки в обеих целях
        #expect(transport.callCount == 2)
    }

    // MARK: - doesNotRetryAlreadyUploaded (нечего слать → 0 запросов, исход не пишется)

    @Test func uploadPending_doesNotRetryAlreadyUploaded_noOutcomeRecorded() async throws {
        let (repo, store, transport, _) = try makeRepo()
        try await store.insertAll([makePoint(id: "p1", uploadedLocal: true, uploadedCloud: true)])

        await repo.uploadPending(raceId: 7, teamId: 42)

        #expect(transport.callCount == 0) // оба fetch'а пусты — POST'а нет
        let byTarget = await repo.outcomes[TrackScope(raceId: 7, teamId: 42)]
        #expect(byTarget == nil) // исход не записан (nil-ветка drainUploadLoop)
    }

    // MARK: - partialAccepted → помечается только пересечение, затем стоп

    @Test func uploadPending_partialAccepted_marksOnlyAccepted_thenBreaks() async throws {
        let (repo, store, transport, _) = try makeRepo()
        // Cloud доставлен → фокус на Local.
        try await store.insertAll([
            makePoint(id: "p1", order: 1, uploadedCloud: true),
            makePoint(id: "p2", order: 2, uploadedCloud: true),
        ])
        // Батч [p1,p2]; accepted = {p1, ghost} → помечен p1, p2 остаётся; второй проход [p2] пуст-accepted → стоп.
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["p1", "ghost"]))
        transport.enqueue(statusCode: 200, bodyString: acceptedBody([]))

        await repo.uploadPending(raceId: 7, teamId: 42)

        let remaining = try await store.unuploadedLocal(raceId: 7, teamId: 42, limit: 1000).map(\.id)
        #expect(remaining == ["p2"]) // p1 помечен, p2 нет
        let outcome = await repo.outcomes[TrackScope(raceId: 7, teamId: 42)]?[.local]
        #expect(outcome?.kind == .error) // второй проход без прогресса → .error
    }

    // MARK: - emptyAccepted → стоп без зацикливания, флаги нетронуты

    @Test func uploadPending_emptyAccepted_breaksWithoutLooping() async throws {
        let (repo, store, transport, _) = try makeRepo()
        try await store.insertAll([makePoint(id: "p1", uploadedCloud: true)])
        transport.enqueue(statusCode: 200, bodyString: acceptedBody([])) // Local: accepted пуст

        await repo.uploadPending(raceId: 7, teamId: 42)

        let remaining = try await store.unuploadedLocal(raceId: 7, teamId: 42, limit: 1000).map(\.id)
        #expect(remaining == ["p1"]) // не помечен
        #expect(transport.callCount == 1) // один upload, стоп (нет бесконечного цикла)
        let outcome = await repo.outcomes[TrackScope(raceId: 7, teamId: 42)]?[.local]
        #expect(outcome?.kind == .error)
    }

    // MARK: - Батчирование >500

    @Test func uploadPending_batchingOver500_multipleRequests_allFlagsSet() async throws {
        let (repo, store, transport, _) = try makeRepo()
        let ids = (0..<600).map { String(format: "p%03d", $0) }
        try await store.insertAll(ids.enumerated().map { i, id in
            makePoint(id: id, order: Int64(i), uploadedCloud: true) // фокус на Local
        })
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(ids)) // Local-батч 1 (500)
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(ids)) // Local-батч 2 (100)

        await repo.uploadPending(raceId: 7, teamId: 42)

        #expect(transport.callCount == 2) // 600 > 500 → два запроса
        let remaining = try await store.unuploadedLocal(raceId: 7, teamId: 42, limit: 1000)
        #expect(remaining.isEmpty)
    }

    // MARK: - uploadAllPending обходит все скоупы

    @Test func uploadAllPending_walksEveryScope() async throws {
        let (repo, store, transport, _) = try makeRepo()
        try await store.insertAll([
            makePoint(id: "p1", teamId: 1),
            makePoint(id: "p2", teamId: 2),
        ])
        // Порядок скоупов из SELECT DISTINCT не гарантирован → каждый ответ несёт ОБА id. 2×2 = 4.
        for _ in 0..<4 {
            transport.enqueue(statusCode: 200, bodyString: acceptedBody(["p1", "p2"]))
        }

        await repo.uploadAllPending()

        let scopes = try await store.pendingUploadScopes()
        #expect(scopes.isEmpty)
        #expect(transport.callCount == 4)
    }

    // MARK: - Реентрантность: перекрывающиеся вызовы → один проход

    @Test func upload_reentrant_isNoOp() async throws {
        let (repo, store, transport, _) = try makeRepo()
        try await store.insertAll([makePoint(id: "p1")])
        // Ровно один проход (Local + Cloud). Если guard не сработает — второй проход опустошит очередь
        // → precondition-краш в FakeTransport.
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["p1"]))
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["p1"]))

        async let a: Void = repo.uploadAllPending()
        async let b: Void = repo.uploadAllPending()
        _ = await (a, b)

        #expect(transport.callCount == 2)
        let scopes = try await store.pendingUploadScopes()
        #expect(scopes.isEmpty)
    }

    // MARK: - Исходы

    @Test func outcome_offlineBothTargets() async throws {
        let (repo, store, transport, _) = try makeRepo()
        try await store.insertAll([makePoint(id: "p1")])
        transport.enqueueError(URLError(.notConnectedToInternet)) // Local обрыв
        transport.enqueueError(URLError(.notConnectedToInternet)) // Cloud обрыв

        await repo.uploadPending(raceId: 7, teamId: 42)

        let byTarget = await repo.outcomes[TrackScope(raceId: 7, teamId: 42)]
        #expect(byTarget?[.local]?.kind == .offline)
        #expect(byTarget?[.cloud]?.kind == .offline)
        let remaining = try await store.pendingUploadScopes()
        #expect(remaining.count == 1) // ничего не помечено — self-heal
    }

    @Test func outcome_drainedOk_reachesStream() async throws {
        let (repo, store, transport, _) = try makeRepo()
        try await store.insertAll([makePoint(id: "p1", uploadedCloud: true)]) // фокус на Local
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["p1"])) // Local .ok

        await repo.uploadPending(raceId: 7, teamId: 42)

        let direct = await repo.outcomes[TrackScope(raceId: 7, teamId: 42)]?[.local]
        #expect(direct?.kind == .ok)
        #expect(direct?.atWallMs == 5000)

        // bufferingNewest(1) держит последний снимок до подписки.
        var received: [TrackScope: [UploadTarget: TargetUploadOutcome]]?
        for await snapshot in repo.outcomeUpdates {
            received = snapshot
            break
        }
        #expect(received?[TrackScope(raceId: 7, teamId: 42)]?[.local]?.kind == .ok)
    }

    @Test func outcome_forbidden403_isError_singleRequest() async throws {
        let (repo, store, transport, _) = try makeRepo()
        try await store.insertAll([makePoint(id: "p1", uploadedCloud: true)])
        transport.enqueue(statusCode: 403) // Local forbidden

        await repo.uploadPending(raceId: 7, teamId: 42)

        let outcome = await repo.outcomes[TrackScope(raceId: 7, teamId: 42)]?[.local]
        #expect(outcome?.kind == .error)
        #expect(transport.callCount == 1) // POST не ретраится
        let remaining = try await store.unuploadedLocal(raceId: 7, teamId: 42, limit: 1000).map(\.id)
        #expect(remaining == ["p1"]) // не помечен
    }

    @Test func outcome_noForwardProgress_isErrorNotOk() async throws {
        let (repo, store, transport, _) = try makeRepo()
        try await store.insertAll([makePoint(id: "p1", uploadedCloud: true)])
        // accepted не пересекается с батчем → нет прогресса → .error (а не .ok).
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["ghost"]))

        await repo.uploadPending(raceId: 7, teamId: 42)

        let outcome = await repo.outcomes[TrackScope(raceId: 7, teamId: 42)]?[.local]
        #expect(outcome?.kind == .error)
    }

    @Test func outcome_nothingPending_notReported() async throws {
        let (repo, store, _, _) = try makeRepo()
        try await store.insertAll([makePoint(id: "p1", uploadedLocal: true, uploadedCloud: true)])

        await repo.uploadPending(raceId: 7, teamId: 42)

        let byTarget = await repo.outcomes[TrackScope(raceId: 7, teamId: 42)]
        #expect(byTarget == nil)
    }

    // MARK: - Ошибка БД в дренаже → .error (прямой тест generic-цикла достаточен, но проверим и актор)

    @Test func dbError_duringMark_recordsErrorOutcome_actorSurvives() async throws {
        let db = try AppDatabase.makeInMemory()
        let store = TrackStore(db.writer)

        let calls = CallCounter()
        // На первом POST'е роняем таблицу track_points — последующий mark-UPDATE бросит.
        let droppingTransport: (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            if calls.next() == 0 {
                try await db.writer.write { db in
                    try db.execute(sql: "DROP TABLE track_points")
                }
            }
            let body = Data(self.acceptedBody(["p1"]).utf8)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (body, resp)
        }
        let cloud = makeClient(base: "https://cloud.test", transport: droppingTransport)
        let local = makeClient(base: "http://local.test", transport: droppingTransport)
        let repo = TrackUploadRepository(trackStore: store, cloud: cloud, local: local, wallNow: { 5000 })
        try await store.insertAll([makePoint(id: "p1", uploadedCloud: true)]) // фокус на Local

        await repo.uploadPending(raceId: 7, teamId: 42) // не роняет процесс

        let outcome = await repo.outcomes[TrackScope(raceId: 7, teamId: 42)]?[.local]
        #expect(outcome?.kind == .error)
        #expect(calls.value == 1) // fetch прошёл, mark бросил — ретрая POST нет
    }
}
