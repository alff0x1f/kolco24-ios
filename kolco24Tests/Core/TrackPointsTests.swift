//
//  TrackPointsTests.swift
//  kolco24Tests
//
//  Зеркало сорт-кейсов `TrackPointMappingTest.kt`: read-time хелпер трека
//  `sortedTrackPoints` — reboot-safe порядок (время фикса раньше монотонного).
//

import Testing
@testable import kolco24

struct TrackPointsTests {

    /// Точка трека с настраиваемыми полями (остальные — нейтральные дефолты).
    private func point(
        id: String = "id",
        accuracy: Float,
        wallMs: Int64 = 0,
        trustedMs: Int64? = nil,
        bootCount: Int? = nil,
        elapsedRealtimeAt: Int64 = 0,
        segmentId: String = "seg"
    ) -> TrackPoint {
        TrackPoint(
            id: id,
            raceId: 1,
            teamId: 1,
            lat: 55.0,
            lon: 37.0,
            accuracy: accuracy,
            gpsTimeMs: 0,
            elapsedRealtimeAt: elapsedRealtimeAt,
            bootCount: bootCount,
            wallMs: wallMs,
            trustedMs: trustedMs,
            segmentId: segmentId
        )
    }

    @Test func sortedTrackPoints_ordersByTrustedOrWallBeforeElapsedAcrossReboot() {
        // "before" фикс: раньше по стенным часам (wallMs 1000), но с бОльшим монотонным штампом
        // (elapsed 100_000) и меньшим bootCount — до ребута.
        let beforeReboot = point(
            id: "before",
            accuracy: 5,
            wallMs: 1_000,
            trustedMs: nil,
            bootCount: 7,
            elapsedRealtimeAt: 100_000,
            segmentId: "before"
        )
        // "after" фикс: позже по стенным часам (2000), но меньший монотонный штамп после ребута.
        let afterReboot = point(
            id: "after",
            accuracy: 5,
            wallMs: 2_000,
            trustedMs: nil,
            bootCount: 8,
            elapsedRealtimeAt: 5_000,
            segmentId: "after"
        )
        #expect(sortedTrackPoints([afterReboot, beforeReboot]).map(\.id) == ["before", "after"])
    }
}
