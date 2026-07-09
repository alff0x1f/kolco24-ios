//
//  TrackStoreTests.swift
//  kolco24Tests
//
//  БОНУС-тесты `TrackStore` поверх in-memory GRDB. На Android `TrackDao` реальным
//  SQL не покрыт (репо-тесты ходят в фейки) — эти кейсы сверх Kotlin: IGNORE-
//  идемпотентность `insertAll`, порядок `observeForTeam`, дренаж с `limit`,
//  `pendingUploadScopes`, скоупинг `uploadCounts`.
//

import GRDB
import Testing
@testable import kolco24

struct TrackStoreTests {

    private func makeStore() throws -> TrackStore {
        TrackStore(try AppDatabase.makeInMemory().writer)
    }

    /// Первое значение observation'а (эмитится сразу на подписке).
    private func firstValue<T>(_ observation: AsyncValueObservation<T>) async throws -> T {
        for try await value in observation {
            return value
        }
        throw CancellationError()
    }

    private func point(
        _ id: String,
        raceId: Int = 1,
        teamId: Int = 7,
        bootCount: Int? = 3,
        elapsedRealtimeAt: Int64 = 500,
        wallMs: Int64 = 1_000,
        trustedMs: Int64? = nil,
        uploadedLocal: Bool = false,
        uploadedCloud: Bool = false
    ) -> TrackPoint {
        TrackPoint(
            id: id,
            raceId: raceId,
            teamId: teamId,
            lat: 55.0,
            lon: 37.0,
            accuracy: 5.0,
            gpsTimeMs: wallMs,
            elapsedRealtimeAt: elapsedRealtimeAt,
            bootCount: bootCount,
            wallMs: wallMs,
            trustedMs: trustedMs,
            segmentId: "seg-1",
            uploadedLocal: uploadedLocal,
            uploadedCloud: uploadedCloud
        )
    }

    @Test func insertAll_isIdempotentOnRepeatedUuid() async throws {
        let store = try makeStore()
        try await store.insertAll([point("dup", wallMs: 1_000)])
        // Re-delivered id with different content must be ignored (IGNORE), not replaced.
        try await store.insertAll([point("dup", wallMs: 9_999), point("new", wallMs: 2_000)])

        let all = try await firstValue(store.observeForTeam(teamId: 7, raceId: 1))
        #expect(all.map(\.id) == ["dup", "new"])
        // Original row survived unchanged.
        #expect(all.first { $0.id == "dup" }?.wallMs == 1_000)
    }

    @Test func observeForTeam_ordersByTrustedThenWallThenBootThenElapsed() async throws {
        let store = try makeStore()
        // "later" no trusted, large wall; "earlier-trusted" small trusted, large wall.
        try await store.insertAll([
            point("later", wallMs: 5_000, trustedMs: nil),
            point("earlier-trusted", wallMs: 9_000, trustedMs: 1_000),
            point("middle", wallMs: 3_000, trustedMs: 3_000),
        ])

        let ordered = try await firstValue(store.observeForTeam(teamId: 7, raceId: 1)).map(\.id)
        #expect(ordered == ["earlier-trusted", "middle", "later"])
    }

    /// Вторичные ключи ORDER BY: `COALESCE(bootCount, -1), elapsedRealtimeAt, id`.
    /// Все точки совпадают по первичному ключу `COALESCE(trustedMs, wallMs) = 1000`,
    /// поэтому проверяются только тай-брейки (bootCount → elapsedRealtimeAt → id).
    @Test func observeForTeam_tieBreaksByBootThenElapsedThenId() async throws {
        let store = try makeStore()
        try await store.insertAll([
            // одинаковые boot=2 и elapsed=200 → тай-брейк по id (asc: "id-a" < "id-b")
            point("id-b", bootCount: 2, elapsedRealtimeAt: 200, wallMs: 1_000),
            point("id-a", bootCount: 2, elapsedRealtimeAt: 200, wallMs: 1_000),
            // boot=2, но elapsed больше → после id-a/id-b
            point("boot2-late", bootCount: 2, elapsedRealtimeAt: 800, wallMs: 1_000),
            // boot=nil → COALESCE(-1) → раньше любого boot>=0
            point("boot-nil", bootCount: nil, elapsedRealtimeAt: 900, wallMs: 1_000),
            // самый большой boot → в конец
            point("boot5", bootCount: 5, elapsedRealtimeAt: 100, wallMs: 1_000),
        ])

        let ordered = try await firstValue(store.observeForTeam(teamId: 7, raceId: 1)).map(\.id)
        #expect(ordered == ["boot-nil", "id-a", "id-b", "boot2-late", "boot5"])
    }

    /// Тот же полный ORDER BY, но по отдельной SQL-строке `unuploadedLocal`.
    @Test func unuploadedLocal_tieBreaksByBootThenElapsedThenId() async throws {
        let store = try makeStore()
        try await store.insertAll([
            point("id-b", bootCount: 2, elapsedRealtimeAt: 200, wallMs: 1_000),
            point("id-a", bootCount: 2, elapsedRealtimeAt: 200, wallMs: 1_000),
            point("boot-nil", bootCount: nil, elapsedRealtimeAt: 900, wallMs: 1_000),
        ])

        let drained = try await store.unuploadedLocal(raceId: 1, teamId: 7, limit: 100).map(\.id)
        #expect(drained == ["boot-nil", "id-a", "id-b"])
    }

    @Test func observeForTeam_isScopedByTeamAndRace() async throws {
        let store = try makeStore()
        try await store.insertAll([
            point("a", raceId: 1, teamId: 7),
            point("b", raceId: 1, teamId: 8),
            point("c", raceId: 2, teamId: 7),
        ])

        let mine = try await firstValue(store.observeForTeam(teamId: 7, raceId: 1)).map(\.id)
        #expect(mine == ["a"])

        let count = try await firstValue(store.countForTeam(teamId: 7, raceId: 1))
        #expect(count == 1)
    }

    @Test func unuploaded_respectsLimitAndTimeOrder() async throws {
        let store = try makeStore()
        try await store.insertAll([
            point("t3", wallMs: 3_000),
            point("t1", wallMs: 1_000),
            point("t2", wallMs: 2_000),
        ])

        let drained = try await store.unuploadedLocal(raceId: 1, teamId: 7, limit: 2).map(\.id)
        #expect(drained == ["t1", "t2"])
    }

    @Test func markUploaded_advancesDrainIndependently() async throws {
        let store = try makeStore()
        try await store.insertAll([point("a", wallMs: 1_000), point("b", wallMs: 2_000), point("c", wallMs: 3_000)])

        try await store.markUploadedLocal(ids: ["a", "b"])
        try await store.markUploadedCloud(ids: ["a"])

        let local = try await store.unuploadedLocal(raceId: 1, teamId: 7, limit: 100).map(\.id)
        let cloud = try await store.unuploadedCloud(raceId: 1, teamId: 7, limit: 100).map(\.id)
        #expect(local == ["c"])
        #expect(cloud == ["b", "c"])
    }

    @Test func uploadCounts_reflectsPerTargetProgressScopedToTeamRace() async throws {
        let store = try makeStore()
        try await store.insertAll([
            point("a", raceId: 1, teamId: 7),
            point("b", raceId: 1, teamId: 7),
            point("other", raceId: 2, teamId: 7, uploadedLocal: true, uploadedCloud: true),
        ])
        try await store.markUploadedLocal(ids: ["a"])

        let counts = try await firstValue(store.uploadCounts(teamId: 7, raceId: 1))
        #expect(counts.total == 2)
        #expect(counts.local == 1)
        #expect(counts.cloud == 0)
    }

    @Test func deleteForTeam_removesOnlyThatScope() async throws {
        let store = try makeStore()
        try await store.insertAll([
            point("a", raceId: 1, teamId: 7),
            point("b", raceId: 2, teamId: 7),
        ])

        try await store.deleteForTeam(teamId: 7, raceId: 1)

        let count1 = try await firstValue(store.countForTeam(teamId: 7, raceId: 1))
        let count2 = try await firstValue(store.countForTeam(teamId: 7, raceId: 2))
        #expect(count1 == 0)
        #expect(count2 == 1)
    }

    @Test func pendingUploadScopes_returnsDistinctScopesWithAnyPendingTarget() async throws {
        let store = try makeStore()
        try await store.insertAll([
            point("done", raceId: 1, teamId: 7, uploadedLocal: true, uploadedCloud: true),
            point("r1t7-second", raceId: 1, teamId: 7, uploadedLocal: false, uploadedCloud: true),
            point("r2t8", raceId: 2, teamId: 8, uploadedLocal: true, uploadedCloud: false),
        ])

        let scopes = Set(try await store.pendingUploadScopes())
        #expect(scopes == [TrackScope(raceId: 1, teamId: 7), TrackScope(raceId: 2, teamId: 8)])
    }
}
