//
//  TrackPointMapperTests.swift
//  kolco24Tests
//
//  Зеркало маппер-кейсов `TrackPointMappingTest.kt` (elapsedRealtimeAt = nanos/1e6,
//  passthrough полей, segmentId/trustedMs из инжектов, altitude-null, idFactory на
//  каждый фикс) + батч-кейсов `insertAll_*` из `TrackRepositoryTest.kt`
//  (back-projection wallMs у каждого фикса, пустой батч, distinct segmentId,
//  trustedMs null без синка) — теперь над чистой `makeTrackPoints`.
//

import Testing
@testable import kolco24

struct TrackPointMapperTests {

    /// Базовый сырой фикс (те же значения, что в `TrackPointMappingTest.kt`).
    private func fix(
        lat: Double = 55.751244,
        lon: Double = 37.618423,
        accuracy: Float = 12.4,
        altitude: Double? = 187.5,
        verticalAccuracyMeters: Float? = 3.2,
        gpsTimeMs: Int64 = 1_718_900_000_000,
        elapsedRealtimeNanos: Int64 = 9_876_543_210_000
    ) -> RawFix {
        RawFix(
            lat: lat,
            lon: lon,
            accuracy: accuracy,
            altitude: altitude,
            verticalAccuracyMeters: verticalAccuracyMeters,
            gpsTimeMs: gpsTimeMs,
            elapsedRealtimeNanos: elapsedRealtimeNanos
        )
    }

    /// Смапить один фикс с настраиваемыми инжектами (снимок батча один на вызов).
    private func map(
        _ f: RawFix,
        raceId: Int = 7,
        teamId: Int = 42,
        segmentId: String = "seg-1",
        wallNow: Int64 = 1_718_900_000_100,
        elapsedNow: Int64 = 9_876_543,
        bootCount: Int? = 3,
        trustedMs: Int64? = 1_718_900_000_123,
        idFactory: @escaping () -> String = { "id-1" }
    ) -> TrackPoint {
        makeTrackPoints(
            fixes: [f],
            raceId: raceId,
            teamId: teamId,
            segmentId: segmentId,
            wallNow: wallNow,
            elapsedNow: elapsedNow,
            bootCount: bootCount,
            trustedMsFor: { _ in trustedMs },
            idFactory: idFactory
        )[0]
    }

    @Test func elapsedRealtimeAt_isNanosDividedByMillion() {
        #expect(map(fix()).elapsedRealtimeAt == 9_876_543)
    }

    @Test func fieldsArePassedThrough() {
        let p = map(fix())
        #expect(p.id == "id-1")
        #expect(p.raceId == 7)
        #expect(p.teamId == 42)
        #expect(p.lat == 55.751244)
        #expect(p.lon == 37.618423)
        #expect(p.accuracy == 12.4)
        #expect(p.altitude == 187.5)
        #expect(p.verticalAccuracyMeters == 3.2)
        #expect(p.gpsTimeMs == 1_718_900_000_000)
        #expect(p.bootCount == 3)
        #expect(p.segmentId == "seg-1")
        #expect(p.uploadedLocal == false)
        #expect(p.uploadedCloud == false)
    }

    @Test func segmentId_comesFromInjectedValue() {
        #expect(map(fix(), segmentId: "session-abc").segmentId == "session-abc")
    }

    @Test func altitudeFields_nullWhenFixHasNoVerticalComponent() {
        let flat = fix(altitude: nil, verticalAccuracyMeters: nil)
        let p = map(flat)
        #expect(p.altitude == nil)
        #expect(p.verticalAccuracyMeters == nil)
    }

    @Test func trustedMs_comesFromInjectedValue() {
        #expect(map(fix(), trustedMs: 1_718_900_000_123).trustedMs == 1_718_900_000_123)
    }

    @Test func trustedMs_nullWhenNoClockSync() {
        #expect(map(fix(), bootCount: nil, trustedMs: nil).trustedMs == nil)
    }

    @Test func idFactoryIsInvokedPerMapping() {
        var counter = 0
        let points = makeTrackPoints(
            fixes: [fix(elapsedRealtimeNanos: 60_000_000_000), fix(elapsedRealtimeNanos: 61_000_000_000)],
            raceId: 1,
            teamId: 1,
            segmentId: "seg",
            wallNow: 0,
            elapsedNow: 0,
            bootCount: nil,
            trustedMsFor: { _ in nil },
            idFactory: { defer { counter += 1 }; return "id-\(counter)" }
        )
        #expect(points.map(\.id) == ["id-0", "id-1"])
    }

    // MARK: - Батч-кейсы insertAll_* (TrackRepositoryTest.kt)

    /// Фикс `TrackRepositoryTest.rawFix`: elapsedRealtimeNanos = elapsedMs * 1e6.
    private func rawFix(elapsedMs: Int64, accuracy: Float = 10) -> RawFix {
        RawFix(
            lat: 55.0,
            lon: 37.0,
            accuracy: accuracy,
            altitude: nil,
            verticalAccuracyMeters: nil,
            gpsTimeMs: 1_718_900_000_000,
            elapsedRealtimeNanos: elapsedMs * 1_000_000
        )
    }

    // Anchor: серверная эпоха 1_700_000_000_000 привязана к монотонным 50_000 в boot-сессии 7.
    private let anchorServerMs: Int64 = 1_700_000_000_000
    private let anchorElapsedMs: Int64 = 50_000

    /// Инжект trusted-времени как `TrustedClock.trustedAt`: serverEpoch + (elapsedAt − anchorElapsed).
    private func trustedMsFor(_ elapsedAt: Int64) -> Int64 {
        anchorServerMs + (elapsedAt - anchorElapsedMs)
    }

    @Test func insertAll_mapsAndStores_withInjectedProviders() {
        var n = 0
        let points = makeTrackPoints(
            fixes: [rawFix(elapsedMs: 60_000)],
            raceId: 1,
            teamId: 7,
            segmentId: "seg",
            wallNow: 2_000_000,
            elapsedNow: 100_000,
            bootCount: 7,
            trustedMsFor: trustedMsFor,
            idFactory: { defer { n += 1 }; return "id-\(n)" }
        )
        #expect(points.count == 1)
        let p = points[0]
        #expect(p.id == "id-0")
        #expect(p.raceId == 1)
        #expect(p.teamId == 7)
        #expect(p.elapsedRealtimeAt == 60_000) // nanos / 1e6
        #expect(p.bootCount == 7)
        // trustedMs = serverEpochMs + (elapsedAt − anchorElapsedMs) = 1_700_000_000_000 + 10_000
        #expect(p.trustedMs == anchorServerMs + 10_000)
        // wallMs = wallNow + (elapsedAt − elapsedNow) = 2_000_000 + (60_000 − 100_000)
        #expect(p.wallMs == 1_960_000)
        #expect(p.segmentId == "seg")
    }

    @Test func insertAll_emptyBatch_isNoOp() {
        let points = makeTrackPoints(
            fixes: [],
            raceId: 1,
            teamId: 7,
            segmentId: "seg",
            wallNow: 2_000_000,
            elapsedNow: 100_000,
            bootCount: 7,
            trustedMsFor: trustedMsFor,
            idFactory: { "id" }
        )
        #expect(points.isEmpty)
    }

    @Test func insertAll_batchOfTwo_eachGetsOwnBackProjectedWallMs() {
        var n = 0
        let points = makeTrackPoints(
            fixes: [rawFix(elapsedMs: 60_000), rawFix(elapsedMs: 64_000)],
            raceId: 1,
            teamId: 7,
            segmentId: "seg",
            wallNow: 2_000_000,
            elapsedNow: 100_000,
            bootCount: 7,
            trustedMsFor: trustedMsFor,
            idFactory: { defer { n += 1 }; return "id-\(n)" }
        )
        #expect(points.map(\.elapsedRealtimeAt) == [60_000, 64_000])
        let a = points[0], b = points[1]
        // Δelapsed = 4_000 → wall и trusted различаются ровно на 4_000.
        #expect(b.wallMs - a.wallMs == 4_000)
        #expect(b.trustedMs! - a.trustedMs! == 4_000)
        #expect(a.wallMs == 1_960_000)
        #expect(b.wallMs == 1_964_000)
    }

    @Test func insertAll_twoSessions_rowsRetainDistinctSegmentIds() {
        // Гарантия stop→start: два вызова с разными segmentId в одном скоупе сохраняют свой segmentId.
        let a = makeTrackPoints(
            fixes: [rawFix(elapsedMs: 60_000)],
            raceId: 1, teamId: 7, segmentId: "seg-A",
            wallNow: 2_000_000, elapsedNow: 100_000, bootCount: 7,
            trustedMsFor: trustedMsFor, idFactory: { "a" }
        )
        let b = makeTrackPoints(
            fixes: [rawFix(elapsedMs: 61_000)],
            raceId: 1, teamId: 7, segmentId: "seg-B",
            wallNow: 2_000_000, elapsedNow: 100_000, bootCount: 7,
            trustedMsFor: trustedMsFor, idFactory: { "b" }
        )
        #expect(a[0].segmentId == "seg-A")
        #expect(b[0].segmentId == "seg-B")
    }

    @Test func insertAll_noClockAnchor_trustedMsNull_wallStillBackProjected() {
        // Без синка (boot null → нет доверенного времени): trustedMs/bootCount == nil, wall честный.
        let points = makeTrackPoints(
            fixes: [rawFix(elapsedMs: 60_000)],
            raceId: 1,
            teamId: 7,
            segmentId: "seg",
            wallNow: 2_000_000,
            elapsedNow: 100_000,
            bootCount: nil,
            trustedMsFor: { _ in nil },
            idFactory: { "id" }
        )
        let p = points[0]
        #expect(p.trustedMs == nil)
        #expect(p.bootCount == nil)
        #expect(p.wallMs == 1_960_000) // wall fallback всё ещё честный per-point
    }
}
