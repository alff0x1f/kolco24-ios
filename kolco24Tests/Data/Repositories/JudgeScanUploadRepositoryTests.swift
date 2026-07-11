//
//  JudgeScanUploadRepositoryTests.swift
//  kolco24Tests
//
//  Поведенческая спека дренажа выгрузки судейских пиков — зеркало upload-части
//  `data/JudgeScanRepositoryTest.kt` поверх РЕАЛЬНОГО `JudgeScanStore` над `AppDatabase.makeInMemory()`
//  + `FakeTransport` (конвенция этапов 2–8). Структурный клон `TrackUploadRepositoryTests` с ключом
//  исходов `raceId` (`Int`), не `TrackScope`.
//
//  **Ловушка `FakeTransport`:** FIFO-очередь ответов по порядку ВЫЗОВОВ (не роутинг по URL); граф
//  даёт cloud и local ОДИН транспорт — ответы энкьюятся в порядке `flushRace` (сначала Local, затем
//  Cloud). Многие тесты ставят `uploadedCloud = 1`, чтобы cloud-дренаж был пуст (returns nil, без
//  транспорта) и оставить фокус на Local.
//

import Foundation
import Testing
import GRDB
@testable import kolco24

struct JudgeScanUploadRepositoryTests {

    // MARK: - Фикстуры

    private func makeScan(
        id: String,
        raceId: Int = 1,
        order: Int64 = 0,
        uploadedLocal: Bool = false,
        uploadedCloud: Bool = false
    ) -> JudgeScan {
        JudgeScan(
            id: id,
            raceId: raceId,
            eventType: "start",
            participantNumber: 100 + Int(order),
            nfcUid: "UID\(id)",
            takenAt: 1_000 + order,
            trustedTakenAt: 2_000 + order,
            elapsedRealtimeAt: 5_000 + order,
            bootCount: 42,
            sourceInstallId: "install-1",
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
    ) throws -> (repo: JudgeScanUploadRepository, store: JudgeScanStore, transport: FakeTransport, db: AppDatabase) {
        let db = try AppDatabase.makeInMemory()
        let store = JudgeScanStore(db.writer)
        let transport = FakeTransport()
        let cloud = makeClient(base: "https://cloud.test", transport: transport.handle)
        let local = makeClient(base: "http://local.test", transport: transport.handle)
        let repo = JudgeScanUploadRepository(
            judgeScanStore: store, cloud: cloud, local: local, installId: "install-1", wallNow: wallNow
        )
        return (repo, store, transport, db)
    }

    private func insert(_ store: JudgeScanStore, _ scans: [JudgeScan]) async throws {
        for scan in scans { try await store.insert(scan) }
    }

    private func acceptedBody(_ ids: [String]) -> String {
        let joined = ids.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"accepted\":[\(joined)]}"
    }

    // MARK: - accepted-subset помечает только принятые, остальное pending

    @Test func uploadPending_acceptedSubset_marksOnlyAcceptedRowsLeavesRestPending() async throws {
        // Зеркало `uploadPending_acceptedSubset_marksOnlyAcceptedRowsLeavesRestPending`.
        let (repo, store, transport, _) = try makeRepo()
        // Local доставлен → фокус на Cloud (flushRace: Local сначала, но здесь оба нужны — упростим:
        // ставим uploadedLocal=1, чтобы фокус остался на Cloud, как cloud-only в Kotlin).
        try await insert(store, [
            makeScan(id: "a", order: 1, uploadedLocal: true),
            makeScan(id: "b", order: 2, uploadedLocal: true),
        ])
        // Cloud-батч [a,b]; accepted = {a} → помечен a, b остаётся; второй проход [b] пуст-accepted → стоп.
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["a"]))
        transport.enqueue(statusCode: 200, bodyString: acceptedBody([]))

        await repo.uploadPending(raceId: 1)

        let remaining = try await store.unuploadedCloud(raceId: 1, limit: 1000).map(\.id)
        #expect(remaining == ["b"]) // a помечен, b нет
        let outcome = await repo.outcomes[1]?[.cloud]
        #expect(outcome?.kind == .error) // второй проход без прогресса → .error
    }

    // MARK: - offline/error оставляет строки pending

    @Test func uploadPending_offlineOrError_leavesRowsPendingForNextTick() async throws {
        // Зеркало `uploadPending_offlineOrError_leavesRowsPendingForNextTick`.
        let (repo, store, transport, _) = try makeRepo()
        try await insert(store, [makeScan(id: "a")])
        transport.enqueueError(URLError(.notConnectedToInternet)) // Local offline
        transport.enqueue(statusCode: 500) // Cloud error

        await repo.uploadPending(raceId: 1)

        let localRemaining = try await store.unuploadedLocal(raceId: 1, limit: 1000).map(\.id)
        let cloudRemaining = try await store.unuploadedCloud(raceId: 1, limit: 1000).map(\.id)
        #expect(localRemaining == ["a"])
        #expect(cloudRemaining == ["a"])
    }

    // MARK: - Дуал-таргет независимость: Local падает, Cloud дренится

    @Test func uploadPending_dualTargetIndependence_oneTargetErrorDoesNotBlockTheOther() async throws {
        // Зеркало `uploadPending_dualTargetIndependence_oneTargetErrorDoesNotBlockTheOther`.
        // flushRace: сначала Local (offline), затем Cloud (success).
        let (repo, store, transport, _) = try makeRepo()
        try await insert(store, [makeScan(id: "a")])
        transport.enqueueError(URLError(.notConnectedToInternet)) // Local offline
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["a"])) // Cloud success

        await repo.uploadPending(raceId: 1)

        let localRemaining = try await store.unuploadedLocal(raceId: 1, limit: 1000).map(\.id)
        let cloudRemaining = try await store.unuploadedCloud(raceId: 1, limit: 1000).map(\.id)
        #expect(localRemaining == ["a"]) // Local не помечен (offline)
        #expect(cloudRemaining.isEmpty) // Cloud дренулся несмотря на провал Local
        #expect(await repo.outcomes[1]?[.local]?.kind == .offline)
        #expect(await repo.outcomes[1]?[.cloud]?.kind == .ok)
    }

    // MARK: - no-progress → .error без зацикливания

    @Test func uploadPending_noForwardProgress_isErrorNotOk() async throws {
        let (repo, store, transport, _) = try makeRepo()
        try await insert(store, [makeScan(id: "a", uploadedLocal: true)]) // фокус на Cloud
        // accepted не пересекается с батчем → нет прогресса → .error.
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["ghost"]))

        await repo.uploadPending(raceId: 1)

        #expect(await repo.outcomes[1]?[.cloud]?.kind == .error)
        let remaining = try await store.unuploadedCloud(raceId: 1, limit: 1000).map(\.id)
        #expect(remaining == ["a"]) // не помечен
        #expect(transport.callCount == 1) // один upload, стоп (нет бесконечного цикла)
    }

    // MARK: - Реентрантность под удержанным замком → no-op

    @Test func upload_reentrant_isNoOp() async throws {
        // Зеркало `uploadPending_reentrantUnderHeldMutex_isNoOp` (идиома `async let` из Track-теста).
        let (repo, store, transport, _) = try makeRepo()
        try await insert(store, [makeScan(id: "a")])
        // Ровно один проход (Local + Cloud). Если guard не сработает — второй проход опустошит очередь
        // → precondition-краш в FakeTransport.
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["a"]))
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["a"]))

        async let x: Void = repo.uploadAllPending()
        async let y: Void = repo.uploadAllPending()
        _ = await (x, y)

        #expect(transport.callCount == 2)
        let races = try await store.pendingUploadRaces()
        #expect(races.isEmpty)
    }

    // MARK: - uploadAllPending обходит все pending-гонки

    @Test func uploadAllPending_walksEveryPendingRace() async throws {
        // Зеркало `uploadAllPending_walksEveryPendingRace`.
        let (repo, store, transport, _) = try makeRepo()
        try await insert(store, [
            makeScan(id: "a", raceId: 1),
            makeScan(id: "b", raceId: 2),
        ])
        // Порядок гонок из SELECT DISTINCT не гарантирован → каждый ответ несёт ОБА id. 2 гонки × 2 цели = 4.
        for _ in 0..<4 {
            transport.enqueue(statusCode: 200, bodyString: acceptedBody(["a", "b"]))
        }

        await repo.uploadAllPending()

        let races = try await store.pendingUploadRaces()
        #expect(races.isEmpty)
        #expect(transport.callCount == 4)
    }

    // MARK: - Обе цели успех → callback .ok для обеих

    @Test func uploadPending_bothTargetsSucceed_outcomeOkForLocalAndCloud() async throws {
        // Зеркало `uploadPending_bothTargetsSucceed_callbackFiresOkForLocalAndCloud`.
        let (repo, store, transport, _) = try makeRepo()
        try await insert(store, [makeScan(id: "a")])
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["a"])) // Local
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["a"])) // Cloud

        await repo.uploadPending(raceId: 1)

        #expect(await repo.outcomes[1]?[.local]?.kind == .ok)
        #expect(await repo.outcomes[1]?[.cloud]?.kind == .ok)
        #expect(await repo.outcomes[1]?[.local]?.atWallMs == 5000)
    }

    // MARK: - offline/error → callback смапленного kind на цель

    @Test func uploadPending_offlineOrError_outcomeMappedKindPerTarget() async throws {
        // Зеркало `uploadPending_offlineOrError_callbackFiresMappedKindPerTarget`.
        let (repo, store, transport, _) = try makeRepo()
        try await insert(store, [makeScan(id: "a")])
        transport.enqueue(statusCode: 500) // Local error
        transport.enqueueError(URLError(.notConnectedToInternet)) // Cloud offline

        await repo.uploadPending(raceId: 1)

        #expect(await repo.outcomes[1]?[.local]?.kind == .error)
        #expect(await repo.outcomes[1]?[.cloud]?.kind == .offline)
    }

    // MARK: - Нечего слать → callback не срабатывает

    @Test func uploadPending_idleReflushWithNothingPending_notReported() async throws {
        // Зеркало `uploadPending_idleReflushWithNothingPending_callbackNotInvoked`.
        let (repo, store, transport, _) = try makeRepo()
        try await insert(store, [makeScan(id: "a", uploadedLocal: true, uploadedCloud: true)])

        await repo.uploadPending(raceId: 1)

        #expect(transport.callCount == 0) // оба fetch'а пусты — POST'а нет
        let byTarget = await repo.outcomes[1]
        #expect(byTarget == nil) // исход не записан (nil-ветка drainUploadLoop)
    }

    // MARK: - Стрим исходов доносит последний снимок

    @Test func outcome_drainedOk_reachesStream() async throws {
        let (repo, store, transport, _) = try makeRepo()
        try await insert(store, [makeScan(id: "a", uploadedLocal: true)]) // фокус на Cloud
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["a"])) // Cloud .ok

        await repo.uploadPending(raceId: 1)

        // bufferingNewest(1) держит последний снимок до подписки.
        var received: [Int: [UploadTarget: TargetUploadOutcome]]?
        for await snapshot in repo.outcomeUpdates {
            received = snapshot
            break
        }
        #expect(received?[1]?[.cloud]?.kind == .ok)
    }
}
