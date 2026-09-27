//
//  TrackLinesTests.swift
//  kolco24Tests
//
//  Зеркало `TrackLinesTest.kt`: `haversineMeters`, `isReachable`, `isShortChain` и фильтр выбросов
//  `trackLines` (голова/внутренние/хвост, жёсткий порог 500 м, раны `segmentId`, режим «Все точки»),
//  плюс `FilteredTrack` (счётчик скрытых точек).
//

import Foundation
import Testing
@testable import kolco24

struct TrackLinesTests {

    private let baseLat = 55.0
    private let baseLon = 37.0

    /// Метров широты на градус для сферы 6_371_000 м — точки по одному меридиану.
    private let mPerDeg = 6_371_000.0 * Double.pi / 180.0

    /// Точка [northM] метров к северу от базы, [tSec] секунд от начала.
    private func pt(
        _ id: String,
        _ tSec: Int64,
        _ northM: Double,
        acc: Float = 10,
        seg: String = "seg",
        trustedMs: Int64? = nil
    ) -> TrackPoint {
        TrackPoint(
            id: id,
            raceId: 1,
            teamId: 1,
            lat: baseLat + northM / mPerDeg,
            lon: baseLon,
            accuracy: acc,
            gpsTimeMs: 0,
            elapsedRealtimeAt: 0,
            wallMs: tSec * 1000,
            trustedMs: trustedMs,
            segmentId: seg
        )
    }

    /// Точка [eastM] метров к востоку от базы (по параллели базы), [tSec] секунд от начала.
    private func ptEast(_ id: String, _ tSec: Int64, _ eastM: Double) -> TrackPoint {
        TrackPoint(
            id: id,
            raceId: 1,
            teamId: 1,
            lat: baseLat,
            lon: baseLon + eastM / (mPerDeg * cos(baseLat * .pi / 180)),
            accuracy: 10,
            gpsTimeMs: 0,
            elapsedRealtimeAt: 0,
            wallMs: tSec * 1000,
            segmentId: "seg"
        )
    }

    /// Пешая цепочка: [n] точек каждые 15 с, шаг 20 м, начиная с [startSec]/[startM].
    private func walk(
        _ prefix: String, _ n: Int, _ startSec: Int64, _ startM: Double,
        acc: Float = 10, seg: String = "seg"
    ) -> [TrackPoint] {
        (0..<n).map { i in pt("\(prefix)\(i)", startSec + 15 * Int64(i), startM + 20.0 * Double(i), acc: acc, seg: seg) }
    }

    private func ids(_ lines: [[TrackPoint]]) -> [[String]] {
        lines.map { $0.map(\.id) }
    }

    private func lines(_ points: [TrackPoint], filter: Bool = true) -> [[String]] {
        ids(trackLines(points, filter: filter))
    }

    // MARK: - haversineMeters

    @Test func haversine_oneDegreeOfLatitude() {
        #expect(abs(haversineMeters(lat1: 55, lon1: 37, lat2: 56, lon2: 37) - mPerDeg) < 0.01)
    }

    @Test func haversine_oneDegreeOfLongitudeAtEquator() {
        #expect(abs(haversineMeters(lat1: 0, lon1: 10, lat2: 0, lon2: 11) - mPerDeg) < 0.01)
    }

    @Test func haversine_oneDegreeOfLongitudeAtMidLatitude() {
        let expected = mPerDeg * cos(55.0 * .pi / 180)
        #expect(abs(haversineMeters(lat1: 55, lon1: 37, lat2: 55, lon2: 38) - expected) < 1)
    }

    @Test func haversine_symmetricAcrossDifferentLatitudes() {
        let there = haversineMeters(lat1: 55, lon1: 37, lat2: 56.5, lon2: 39)
        let back = haversineMeters(lat1: 56.5, lon1: 39, lat2: 55, lon2: 37)
        #expect(abs(there - back) < 1e-6)
        let mskSpb = haversineMeters(lat1: 55.7558, lon1: 37.6173, lat2: 59.9343, lon2: 30.3351)
        #expect(abs(mskSpb - 634_000) < 3_000)
    }

    @Test func haversine_samePointIsZero() {
        #expect(haversineMeters(lat1: 55.75, lon1: 37.62, lat2: 55.75, lon2: 37.62) == 0)
    }

    // MARK: - isReachable

    @Test func isReachable_speedBoundaryAround14mps() {
        let a = pt("a", 0, 0, acc: 0)
        #expect(isReachable(a, pt("b", 10, 139.9, acc: 0)))
        #expect(!isReachable(a, pt("b", 10, 140.1, acc: 0)))
    }

    @Test func isReachable_subtractsTheBetterAccuracyAsNoiseAllowance() {
        #expect(isReachable(pt("a", 0, 0, acc: 60), pt("b", 15, 250, acc: 90)))
        #expect(!isReachable(pt("a", 0, 0, acc: 10), pt("b", 15, 250, acc: 90)))
    }

    @Test func isReachable_usesTrustedTimeOverWallTime() {
        #expect(isReachable(pt("a", 0, 0, trustedMs: 0), pt("b", 15, 1000, trustedMs: 100_000)))
        #expect(!isReachable(pt("a", 0, 0), pt("b", 15, 1000)))
    }

    // MARK: - trackLines, фильтр включён

    @Test func spikeBetweenShortChains_bypassReachable_droppedIntoOneLine() {
        let points = [pt("A", 0, 0), pt("B", 15, 20), pt("X", 30, 1000), pt("C", 45, 60), pt("D", 60, 80)]
        #expect(lines(points) == [["A", "B", "C", "D"]])
    }

    @Test func shortTailAfterShortChain_keptAsOwnLine() {
        let points = [pt("A", 0, 0, acc: 5), pt("B", 15, 200, acc: 20), pt("C", 30, 500, acc: 10)]
        #expect(lines(points) == [["A", "B"], ["C"]])
    }

    @Test func realisticCoarseSpikeBetweenLongChains_dropped() {
        let first = walk("a", 5, 0, 0)
        let second = walk("b", 5, 90, 120)
        let points = first + [pt("S", 75, 680, acc: 450)] + second
        #expect(lines(points) == [(first + second).map(\.id)])
    }

    @Test func multipathSpikeWithGoodAccuracy_dropped() {
        let first = walk("a", 5, 0, 0, acc: 15)
        let second = walk("b", 5, 90, 120, acc: 15)
        let points = first + [pt("S", 75, 380, acc: 8)] + second
        #expect(lines(points) == [(first + second).map(\.id)])
    }

    @Test func slowNoisyJitter_keptAsOneLine() {
        let offsets: [Double] = [0, 80, -60, 90, -80, 70, 0, -90]
        let accs: [Float] = [60, 100, 70, 90, 80, 100, 60, 75]
        let points = offsets.indices.map { i in
            pt("j\(i)", 15 * Int64(i), offsets[i] + 5.0 * Double(i), acc: accs[i])
        }
        #expect(lines(points) == [points.map(\.id)])
    }

    @Test func noisyJitterNeedingNoiseAllowance_keptAsOneLine() {
        let points = (0..<6).map { i in pt("j\(i)", 15 * Int64(i), i % 2 == 0 ? 0 : 250, acc: 60 + Float(i)) }
        #expect(lines(points) == [points.map(\.id)])
    }

    @Test func eastWestStep_measuredWithLongitudeCosine_oneLine() {
        #expect(lines([ptEast("a", 0, 0), ptEast("b", 15, 200)]) == [["a", "b"]])
    }

    @Test func eastWestSpikeBetweenLongChains_dropped() {
        let first = (0..<5).map { i in ptEast("a\(i)", 15 * Int64(i), 20.0 * Double(i)) }
        let second = (0..<5).map { i in ptEast("b\(i)", 90 + 15 * Int64(i), 120.0 + 20.0 * Double(i)) }
        #expect(lines(first + [ptEast("S", 75, 880)] + second) == [(first + second).map(\.id)])
    }

    @Test func twoMutuallyUnreachableSpikesInARow_bothKeptEachOwnLine() {
        let l = walk("l", 5, 0, 0)
        let r = walk("r", 5, 105, 120)
        let points = l + [pt("X", 75, 3000), pt("Y", 90, -3000)] + r
        #expect(lines(points) == [l.map(\.id), ["X"], ["Y"], r.map(\.id)])
    }

    @Test func liveTail_keptUntilNextFixMakesItABypassableInteriorChain() {
        let gps = walk("g", 5, 0, 0)
        let jump = pt("X", 75, 2000)
        #expect(lines(gps + [jump]) == [gps.map(\.id), ["X"]])
        let next = pt("g5", 90, 100)
        #expect(lines(gps + [jump, next]) == [(gps + [next]).map(\.id)])
    }

    @Test func headNetworkClusterBeforeLongChain_dropped() {
        let cluster = [pt("n0", 0, 3000, acc: 300), pt("n1", 15, 3050, acc: 320), pt("n2", 30, 2980, acc: 280)]
        let gps = walk("g", 6, 45, 0)
        #expect(lines(cluster + gps) == [gps.map(\.id)])
    }

    @Test func shortHeadBeforeShortChain_kept() {
        let points = [pt("h0", 0, 0), pt("h1", 15, 20), pt("s0", 30, 2000), pt("s1", 45, 2020)]
        #expect(lines(points) == [["h0", "h1"], ["s0", "s1"]])
    }

    @Test func trailingNetworkFixesAfterLongChain_dropped() {
        let gps = walk("g", 5, 0, 0)
        let tail = [pt("n0", 75, 2000, acc: 300), pt("n1", 90, 2050, acc: 310)]
        #expect(lines(gps + tail) == [gps.map(\.id)])
    }

    @Test func trailingGpsQualityShortChainAfterBreak_keptAsOwnLine() {
        let gps = walk("g", 5, 0, 0)
        let tail = [pt("t0", 75, 1080, acc: 12), pt("t1", 90, 1100, acc: 12)]
        #expect(lines(gps + tail) == [gps.map(\.id), ["t0", "t1"]])
    }

    /// Длинная цепочка (5 точек, 60 с, шаг 20 м); медиана (5,5,10,50,50) = 10.
    private func longWithAccs(_ accs: [Float] = [5, 50, 10, 50, 5]) -> [TrackPoint] {
        accs.enumerated().map { i, acc in pt("g\(i)", 15 * Int64(i), 20.0 * Double(i), acc: acc) }
    }

    private func farTail(_ accs: Float...) -> [TrackPoint] {
        accs.enumerated().map { i, acc in pt("t\(i)", 75 + 15 * Int64(i), 2000 + 20.0 * Double(i), acc: acc) }
    }

    @Test func tail_exactlyThreeTimesWorseMedian_dropped() {
        let gps = longWithAccs()
        #expect(lines(gps + farTail(30, 30)) == [gps.map(\.id)])
    }

    @Test func tail_justUnderThreeTimesWorseMedian_kept() {
        let gps = longWithAccs()
        let tail = farTail(29, 29)
        #expect(lines(gps + tail) == [gps.map(\.id), tail.map(\.id)])
    }

    @Test func tail_evenSizeMedianIsMeanOfTheMiddles() {
        let gps = longWithAccs()
        #expect(lines(gps + farTail(29, 31)) == [gps.map(\.id)])
        let tail = farTail(20, 38)
        #expect(lines(gps + tail) == [gps.map(\.id), tail.map(\.id)])
    }

    @Test func tail_afterShortChain_keptEvenWhenMuchWorse() {
        let l = walk("l", 5, 0, 0)
        let s = [pt("s0", 75, 2000), pt("s1", 90, 2020)]
        let t = [pt("t0", 105, 6000, acc: 300), pt("t1", 120, 6020, acc: 300)]
        #expect(lines(l + s + t) == [l.map(\.id), s.map(\.id), t.map(\.id)])
    }

    @Test func tail_referenceMedianZeroIsFlooredAtOneMeter() {
        let gps = longWithAccs([0, 0, 0, 0, 0])
        let kept = farTail(2, 2)
        #expect(lines(gps + kept) == [gps.map(\.id), kept.map(\.id)])
        #expect(lines(gps + farTail(3, 3)) == [gps.map(\.id)])
    }

    @Test func interiorShortChainWithUnreachableBypass_keptAsOwnLine() {
        let first = walk("a", 5, 0, 0)
        let mid = [pt("m0", 75, 1000), pt("m1", 90, 1020)]
        let second = walk("b", 5, 105, 5000)
        #expect(lines(first + mid + second) == [first.map(\.id), ["m0", "m1"], second.map(\.id)])
    }

    @Test func twoLongChainsWithUnreachableStep_twoLines() {
        let first = walk("a", 5, 0, 0)
        let second = walk("b", 5, 75, 3000)
        #expect(lines(first + second) == [first.map(\.id), second.map(\.id)])
    }

    @Test func segmentOfOnlyShortChains_noPointsRemoved() {
        let points = [pt("p0", 0, 0), pt("p1", 15, 2000), pt("p2", 30, 4000), pt("p3", 45, 6000)]
        let result = trackLines(points, filter: true)
        #expect(result.flatMap { $0 }.map(\.id) == points.map(\.id))
        #expect(result.count == 4)
    }

    @Test func differentSegmentIds_neverMerged() {
        let points = [
            pt("a0", 0, 0, seg: "a"), pt("a1", 15, 20, seg: "a"),
            pt("b0", 30, 40, seg: "b"), pt("b1", 45, 60, seg: "b"),
        ]
        #expect(lines(points) == [["a0", "a1"], ["b0", "b1"]])
    }

    @Test func hardCap_above500Dropped_exactly500Kept() {
        let points = [pt("at", 0, 0, acc: 500), pt("over", 15, 10, acc: 501), pt("fine", 30, 20, acc: 10)]
        #expect(lines(points) == [["at", "fine"]])
    }

    @Test func hardCap_allOverCap_empty() {
        #expect(trackLines([pt("a", 0, 0, acc: 600), pt("b", 15, 20, acc: 900)], filter: true).isEmpty)
    }

    @Test func hardCap_removesSpikesThatWouldOtherwiseSplitTheTrack() {
        let l = walk("l", 5, 0, 0)
        let r = walk("r", 5, 105, 120)
        let points = l + [pt("X", 75, 3000, acc: 501), pt("Y", 90, -3000, acc: 600)] + r
        #expect(lines(points) == [(l + r).map(\.id)])
    }

    @Test func filterOn_eachSegmentRunFilteredOnItsOwn() {
        let a = walk("a", 3, 0, 0, seg: "a")
        let bHead = [pt("bn0", 60, 5000, acc: 300, seg: "b"), pt("bn1", 75, 5050, acc: 300, seg: "b")]
        let bGps = walk("b", 5, 90, 100, seg: "b")
        let a2 = walk("c", 2, 180, 200, seg: "a")
        #expect(lines(a + bHead + bGps + a2) == [a.map(\.id), bGps.map(\.id), a2.map(\.id)])
    }

    @Test func zeroDt_usesOneSecondFloor() {
        #expect(lines([pt("a", 0, 0, acc: 5), pt("b", 0, 10, acc: 5)]) == [["a", "b"]])
        #expect(lines([pt("a", 0, 0, acc: 5), pt("b", 0, 30, acc: 5)]) == [["a"], ["b"]])
    }

    @Test func shortChainBoundaries() {
        #expect(isShortChain([pt("a", 0, 0)]))
        #expect(isShortChain([pt("a", 0, 0), pt("b", 30, 0), pt("c", 59, 0)]))
        #expect(!isShortChain([pt("a", 0, 0), pt("b", 30, 0), pt("c", 60, 0)]))
        #expect(!isShortChain(walk("w", 4, 0, 0)))
    }

    @Test func emptyInput_emptyList() {
        #expect(trackLines([], filter: true).isEmpty)
        #expect(trackLines([], filter: false).isEmpty)
    }

    // MARK: - trackLines, фильтр выключен («Все точки»)

    @Test func filterOff_onlySplitsByConsecutiveSegmentId() {
        let points = [
            pt("a0", 0, 0, seg: "a"),
            pt("spike", 15, 5000, acc: 900, seg: "a"),
            pt("a1", 30, 40, seg: "a"),
            pt("b0", 45, 60, seg: "b"),
            pt("a2", 60, 80, seg: "a"),
        ]
        #expect(lines(points, filter: false) == [["a0", "spike", "a1"], ["b0"], ["a2"]])
    }

    // MARK: - FilteredTrack

    @Test func filteredTrack_sortsRawInputAndCountsHidden() {
        let first = walk("a", 5, 0, 0)
        let second = walk("b", 5, 90, 120)
        let spike = pt("S", 75, 680, acc: 450)
        let raw = (first + [spike] + second).reversed()

        let filtered = FilteredTrack(raw: Array(raw), showAllPoints: false)
        #expect(filtered.points.map(\.id) == (first + second).map(\.id))
        #expect(filtered.hiddenCount == 1)

        let all = FilteredTrack(raw: Array(raw), showAllPoints: true)
        #expect(all.points.count == 11)
        #expect(all.hiddenCount == 0)
    }
}
