//
//  GpxExportTests.swift
//  kolco24Tests
//
//  Зеркало `GpxExportTest.kt` (8 кейсов): GPX 1.1-сериализация трека — пустой
//  трек, отдельные `<trkseg>` по `segmentId`, reboot-safe порядок вызывающей
//  стороны, `<ele>` только при altitude, `<time>` trusted→wall в UTC ISO,
//  точка-разделитель координат, XML-эскейп имени, санитизация имени файла.
//

import Testing
@testable import kolco24

struct GpxExportTests {

    /// Точка трека с настраиваемыми полями (остальные — нейтральные дефолты).
    private func point(
        id: String,
        lat: Double,
        lon: Double,
        segmentId: String,
        altitude: Double? = nil,
        trustedMs: Int64? = nil,
        wallMs: Int64 = 1_718_900_000_000,
        elapsedRealtimeAt: Int64 = 0,
        bootCount: Int? = nil
    ) -> TrackPoint {
        TrackPoint(
            id: id,
            raceId: 7,
            teamId: 42,
            lat: lat,
            lon: lon,
            accuracy: 8,
            altitude: altitude,
            verticalAccuracyMeters: nil,
            gpsTimeMs: 0,
            elapsedRealtimeAt: elapsedRealtimeAt,
            bootCount: bootCount,
            wallMs: wallMs,
            trustedMs: trustedMs,
            segmentId: segmentId
        )
    }

    private func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    @Test func emptyList_producesValidEmptyTrack() {
        let gpx = buildGpx(points: [], trackName: "Команда")
        #expect(gpx.hasPrefix("<?xml"))
        #expect(gpx.contains("<trk>"))
        #expect(gpx.contains("</trk>"))
        #expect(!gpx.contains("<trkpt"))
        #expect(!gpx.contains("<trkseg>"))
    }

    @Test func distinctSegmentIds_produceSeparateTrksegs() {
        let gpx = buildGpx(
            points: [
                point(id: "a", lat: 55.0, lon: 37.0, segmentId: "s1"),
                point(id: "b", lat: 55.1, lon: 37.1, segmentId: "s1"),
                point(id: "c", lat: 55.2, lon: 37.2, segmentId: "s2"),
            ],
            trackName: "T"
        )
        #expect(count("<trkseg>", in: gpx) == 2)
        #expect(count("</trkseg>", in: gpx) == 2)
        #expect(count("<trkpt", in: gpx) == 3)
    }

    @Test func callerSideRebootSafeSorting_preventsAlternatingOnePointSegments() {
        let points = sortedTrackPoints([
            point(id: "old-1", lat: 55.0, lon: 37.0, segmentId: "old", wallMs: 1_000, elapsedRealtimeAt: 100_000, bootCount: 7),
            point(id: "new-1", lat: 56.0, lon: 38.0, segmentId: "new", wallMs: 10_000, elapsedRealtimeAt: 101_000, bootCount: 8),
            point(id: "old-2", lat: 55.1, lon: 37.1, segmentId: "old", wallMs: 2_000, elapsedRealtimeAt: 102_000, bootCount: 7),
            point(id: "new-2", lat: 56.1, lon: 38.1, segmentId: "new", wallMs: 11_000, elapsedRealtimeAt: 103_000, bootCount: 8),
        ])

        let gpx = buildGpx(points: points, trackName: "T")

        #expect(points.map(\.id) == ["old-1", "old-2", "new-1", "new-2"])
        #expect(count("<trkseg>", in: gpx) == 2)
        #expect(count("<trkpt", in: gpx) == 4)
    }

    @Test func altitude_omittedWhenNull_presentWhenSet() {
        let gpx = buildGpx(
            points: [
                point(id: "a", lat: 55.0, lon: 37.0, segmentId: "s", altitude: nil),
                point(id: "b", lat: 55.1, lon: 37.1, segmentId: "s", altitude: 187.5),
            ],
            trackName: "T"
        )
        #expect(count("<ele>", in: gpx) == 1)
        #expect(gpx.contains("<ele>187.500000</ele>"))
    }

    @Test func time_usesTrustedThenWall_inUtcIso() {
        // 2024-06-20T18:53:20Z = 1_718_909_600_000 ms.
        let gpx = buildGpx(
            points: [
                point(id: "a", lat: 55.0, lon: 37.0, segmentId: "s", trustedMs: 1_718_909_600_000, wallMs: 0),
                point(id: "b", lat: 55.1, lon: 37.1, segmentId: "s", trustedMs: nil, wallMs: 1_718_909_600_000),
            ],
            trackName: "T"
        )
        #expect(count("<time>2024-06-20T18:53:20Z</time>", in: gpx) == 2)
    }

    @Test func coordinates_useDotDecimalSeparator() {
        let gpx = buildGpx(
            points: [point(id: "a", lat: 55.751244, lon: 37.618423, segmentId: "s")],
            trackName: "T"
        )
        #expect(gpx.contains("lat=\"55.751244\""))
        #expect(gpx.contains("lon=\"37.618423\""))
    }

    @Test func trackName_isXmlEscaped() {
        let gpx = buildGpx(points: [], trackName: "A & B <test>")
        #expect(gpx.contains("<name>A &amp; B &lt;test&gt;</name>"))
    }

    @Test func fileName_sanitizesAndStamps() {
        #expect(gpxFileName(teamLabel: "148", dateIso: "2026-06-26") == "kolco24-148-2026-06-26.gpx")
        #expect(gpxFileName(teamLabel: "team 7", dateIso: "2026-06-26") == "kolco24-team_7-2026-06-26.gpx")
        #expect(gpxFileName(teamLabel: "", dateIso: "2026-06-26") == "kolco24-track-2026-06-26.gpx")
    }
}
