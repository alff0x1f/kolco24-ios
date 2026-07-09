//
//  JudgeScanStoreTests.swift
//  kolco24Tests
//
//  Зеркало `JudgeScanDaoTest.kt` (7 кейсов) поверх in-memory GRDB — скоупинг по
//  `raceId`, trusted-then-wall сортировка и write-once upload-флаги. Имена кейсов
//  и сценарии 1:1 с Kotlin.
//

import GRDB
import Testing
@testable import kolco24

struct JudgeScanStoreTests {

    private func makeStore() throws -> JudgeScanStore {
        JudgeScanStore(try AppDatabase.makeInMemory().writer)
    }

    /// Первое значение observation'а (эмитится сразу на подписке).
    private func firstValue<T>(_ observation: AsyncValueObservation<T>) async throws -> T {
        for try await value in observation {
            return value
        }
        throw CancellationError()
    }

    /// Зеркало `JudgeScanDaoTest.scan(...)`.
    private func scan(
        _ id: String,
        raceId: Int = 1,
        eventType: String = "start",
        participantNumber: Int = 42,
        nfcUid: String = "AABBCC",
        takenAt: Int64 = 1_000,
        trustedTakenAt: Int64? = nil,
        elapsedRealtimeAt: Int64 = 500,
        bootCount: Int? = 3,
        sourceInstallId: String = "install-1",
        uploadedLocal: Bool = false,
        uploadedCloud: Bool = false
    ) -> JudgeScan {
        JudgeScan(
            id: id,
            raceId: raceId,
            eventType: eventType,
            participantNumber: participantNumber,
            nfcUid: nfcUid,
            takenAt: takenAt,
            trustedTakenAt: trustedTakenAt,
            elapsedRealtimeAt: elapsedRealtimeAt,
            bootCount: bootCount,
            sourceInstallId: sourceInstallId,
            uploadedLocal: uploadedLocal,
            uploadedCloud: uploadedCloud
        )
    }

    // MARK: - Зеркала JudgeScanDaoTest.kt (7 кейсов)

    @Test func unuploadedLocalAndCloud_scopedByRaceId() async throws {
        let store = try makeStore()
        try await store.insert(scan("race1-a", raceId: 1))
        try await store.insert(scan("race1-b", raceId: 1, uploadedLocal: true, uploadedCloud: true))
        try await store.insert(scan("race2-a", raceId: 2))

        let local = try await store.unuploadedLocal(raceId: 1, limit: 100).map(\.id)
        let cloud = try await store.unuploadedCloud(raceId: 1, limit: 100).map(\.id)

        #expect(local == ["race1-a"])
        #expect(cloud == ["race1-a"])
    }

    @Test func unuploadedLocal_orderedByTrustedThenWallTime() async throws {
        // "later" has no trusted time and a later wall time than "earlier-trusted" — but since
        // "earlier-trusted"'s trusted time is small, it must still sort first via COALESCE.
        let store = try makeStore()
        try await store.insert(scan("later", takenAt: 5_000, trustedTakenAt: nil))
        try await store.insert(scan("earlier-trusted", takenAt: 9_000, trustedTakenAt: 1_000))
        try await store.insert(scan("middle", takenAt: 3_000, trustedTakenAt: 3_000))

        let ordered = try await store.unuploadedLocal(raceId: 1, limit: 100).map(\.id)

        #expect(ordered == ["earlier-trusted", "middle", "later"])
    }

    @Test func markUploadedLocalAndCloud_flipsOnlyGivenRows() async throws {
        let store = try makeStore()
        try await store.insert(scan("a"))
        try await store.insert(scan("b"))
        try await store.insert(scan("c"))

        try await store.markUploadedLocal(ids: ["a", "b"])
        try await store.markUploadedCloud(ids: ["a"])

        let remainingLocal = Set(try await store.unuploadedLocal(raceId: 1, limit: 100).map(\.id))
        let remainingCloud = Set(try await store.unuploadedCloud(raceId: 1, limit: 100).map(\.id))

        #expect(remainingLocal == ["c"])
        #expect(remainingCloud == ["b", "c"])
    }

    @Test func pendingUploadRaces_returnsDistinctRacesWithAnyPendingTarget() async throws {
        let store = try makeStore()
        try await store.insert(scan("r1-fully-uploaded", raceId: 1, uploadedLocal: true, uploadedCloud: true))
        try await store.insert(scan("r2-local-pending", raceId: 2, uploadedLocal: false, uploadedCloud: true))
        try await store.insert(scan("r2-second", raceId: 2, uploadedLocal: true, uploadedCloud: true))
        try await store.insert(scan("r3-cloud-pending", raceId: 3, uploadedLocal: true, uploadedCloud: false))

        let pending = try await store.pendingUploadRaces()

        #expect(Set(pending) == [2, 3])
        #expect(!pending.contains(1))
    }

    @Test func uploadCounts_reflectsInsertsWithNoneUploaded() async throws {
        let store = try makeStore()
        try await store.insert(scan("a", raceId: 1))
        try await store.insert(scan("b", raceId: 1))

        let counts = try await firstValue(store.uploadCounts(raceId: 1))

        #expect(counts.total == 2)
        #expect(counts.local == 0)
        #expect(counts.cloud == 0)
    }

    @Test func uploadCounts_localAndCloudAdvanceIndependently() async throws {
        let store = try makeStore()
        try await store.insert(scan("a", raceId: 1))
        try await store.insert(scan("b", raceId: 1))
        try await store.insert(scan("c", raceId: 1))

        try await store.markUploadedLocal(ids: ["a", "b"])
        try await store.markUploadedCloud(ids: ["a"])

        let counts = try await firstValue(store.uploadCounts(raceId: 1))

        #expect(counts.total == 3)
        #expect(counts.local == 2)
        #expect(counts.cloud == 1)
    }

    @Test func uploadCounts_excludesOtherRaceIds() async throws {
        let store = try makeStore()
        try await store.insert(scan("race1-a", raceId: 1))
        try await store.insert(scan("race2-a", raceId: 2, uploadedLocal: true, uploadedCloud: true))

        let counts = try await firstValue(store.uploadCounts(raceId: 1))

        #expect(counts.total == 1)
        #expect(counts.local == 0)
        #expect(counts.cloud == 0)
    }
}
