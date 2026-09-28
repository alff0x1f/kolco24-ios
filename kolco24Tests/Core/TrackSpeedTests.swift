//
//  TrackSpeedTests.swift
//  kolco24Tests
//
//  Раскраска трека по скорости: диапазоны `speedBand`, скорость по окну `stepSpeedsMps`.
//

import Foundation
import Testing
@testable import kolco24

struct TrackSpeedTests {

    private let baseLat = 55.0
    private let baseLon = 37.0

    /// Метров широты на градус для сферы 6_371_000 м — точки по одному меридиану.
    private let mPerDeg = 6_371_000.0 * Double.pi / 180.0

    /// 4 км/ч в м/с и путь за 15 с на этой скорости.
    private let walkMps = 4.0 / 3.6
    private var walkStepM: Double { walkMps * 15 }

    /// Точка [northM] метров к северу и [eastM] к востоку от базы, [tSec] секунд от начала.
    private func pt(
        _ tSec: Int64, _ northM: Double, eastM: Double = 0, acc: Float = 10, seg: String = "seg"
    ) -> TrackPoint {
        ptMs(tSec * 1000, northM, eastM: eastM, acc: acc, seg: seg)
    }

    private func ptMs(
        _ ms: Int64, _ northM: Double, eastM: Double = 0, acc: Float = 10, seg: String = "seg"
    ) -> TrackPoint {
        TrackPoint(
            id: "p\(ms)",
            raceId: 1,
            teamId: 1,
            lat: baseLat + northM / mPerDeg,
            lon: baseLon + eastM / (mPerDeg * cos(baseLat * .pi / 180)),
            accuracy: acc,
            gpsTimeMs: 0,
            elapsedRealtimeAt: 0,
            wallMs: ms,
            segmentId: seg
        )
    }

    /// Детерминированный непериодический шум в пределах ±[amplitude] м (золотое сечение — без повторов).
    private func jitter(_ i: Int, _ amplitude: Double) -> (north: Double, east: Double) {
        let phi = 0.618_033_988_75
        let u = (Double(i) * phi).truncatingRemainder(dividingBy: 1)
        let v = (Double(i) * phi * phi + 0.3).truncatingRemainder(dividingBy: 1)
        return ((u * 2 - 1) * amplitude, (v * 2 - 1) * amplitude)
    }

    /// [count] точек через 15 с, начиная с [startSec]/[startM], со скоростью [mps].
    private func steady(count: Int, startSec: Int64 = 0, startM: Double = 0, mps: Double) -> [TrackPoint] {
        (0..<count).map { i in pt(startSec + Int64(i) * 15, startM + Double(i) * 15 * mps) }
    }

    private func isClose(_ a: Double, _ b: Double, tol: Double = 1e-3) -> Bool {
        abs(a - b) <= tol
    }

    // MARK: - speedBand

    @Test func speedBandBoundariesAreLowerInclusive() {
        #expect(speedBand(kmh: 0) == .stop)
        #expect(speedBand(kmh: 0.99) == .stop)
        #expect(speedBand(kmh: 1.0) == .slow)
        #expect(speedBand(kmh: 2.99) == .slow)
        #expect(speedBand(kmh: 3.0) == .walk)
        #expect(speedBand(kmh: 4.99) == .walk)
        #expect(speedBand(kmh: 5.0) == .brisk)
        #expect(speedBand(kmh: 6.99) == .brisk)
        #expect(speedBand(kmh: 7.0) == .fast)
        #expect(speedBand(kmh: 60) == .fast)
    }

    @Test func legendLabelsFollowBandLimits() {
        #expect(SpeedBand.allCases.map(speedBandLegendLabel) == ["<1", "1–3", "3–5", "5–7", "7+"])
    }

    // MARK: - stepSpeedsMps

    @Test func steadyWalkGivesWalkSpeedOnEveryStep() {
        let speeds = stepSpeedsMps(steady(count: 20, mps: walkMps))
        #expect(speeds.count == 19)
        #expect(speeds.allSatisfy { isClose($0, walkMps) })
    }

    @Test func stationaryJitterStaysBelowOneKmh() {
        let line = (0..<20).map { i in pt(Int64(i) * 15, i % 2 == 0 ? -10 : 10) }
        let speeds = stepSpeedsMps(line)
        #expect(speeds.allSatisfy { $0 * 3.6 < 1 })
    }

    @Test func longStepUsesOwnSpeedAndWindowDoesNotCrossIt() {
        // 4 км/ч, затем шаг 300 с на 30 м, затем 8 км/ч.
        let left = steady(count: 7, mps: walkMps)
        let leftEnd = left.last!
        let leftEndM = 6 * walkStepM
        let right = steady(count: 7, startSec: 90 + 300, startM: leftEndM + 30, mps: 2 * walkMps)
        let speeds = stepSpeedsMps(left + right)

        #expect(speeds.count == 13)
        #expect(speeds[0..<6].allSatisfy { isClose($0, walkMps) })
        #expect(isClose(speeds[6], 30.0 / 300.0))
        #expect(speeds[7...].allSatisfy { isClose($0, 2 * walkMps) })
        #expect(trackPointTimeMs(leftEnd) == 90_000)
    }

    @Test func windowAtLineStartGrowsRight() {
        // Первый шаг — движение, дальше стоим: окно шага 0 растёт вправо до 90 с.
        let line = [pt(0, 0)] + (1..<10).map { i in pt(Int64(i) * 15, walkStepM) }
        let speeds = stepSpeedsMps(line)
        #expect(isClose(speeds[0], walkStepM / 90))
    }

    @Test func windowAtLineEndGrowsLeft() {
        let line = (0..<9).map { i in pt(Int64(i) * 15, 0) } + [pt(135, walkStepM)]
        let speeds = stepSpeedsMps(line)
        #expect(isClose(speeds[8], walkStepM / 90))
    }

    @Test func lineShorterThanWindowUsesWholeLine() {
        let speeds = stepSpeedsMps([pt(0, 0), pt(15, 20), pt(30, 50)])
        #expect(speeds.count == 2)
        #expect(speeds.allSatisfy { isClose($0, 50.0 / 30.0) })
    }

    @Test func twoPointLineIsDistanceOverTime() {
        let speeds = stepSpeedsMps([pt(0, 0), pt(15, 30)])
        #expect(speeds.count == 1)
        #expect(isClose(speeds[0], 2))
    }

    @Test func zeroDtUsesOneSecondFloor() {
        let speeds = stepSpeedsMps([pt(0, 0), pt(0, 5)])
        #expect(isClose(speeds[0], 5))
    }

    @Test func shortInputsGiveNoSpeeds() {
        #expect(stepSpeedsMps([]).isEmpty)
        #expect(stepSpeedsMps([pt(0, 0)]).isEmpty)
    }

    // MARK: - stepStrokes

    @Test func normalStepsMapToBands() {
        #expect(stepStrokes(steady(count: 10, mps: walkMps)).allSatisfy { $0 == .band(.walk) })
        #expect(stepStrokes(steady(count: 10, mps: 2 / 3.6)).allSatisfy { $0 == .band(.slow) })
    }

    @Test func longStepAtRestIsStop() {
        let strokes = stepStrokes([pt(0, 0), pt(600, 5)])
        #expect(strokes == [.band(.stop)])
    }

    @Test func longStepWithDisplacementIsGap() {
        let strokes = stepStrokes([pt(0, 0), pt(600, 700)])
        #expect(strokes == [.gap])
    }

    @Test func longOutageWhileMovingIsGapNotStop() {
        // Час без фиксов, концы в 800 м: средняя 0,8 км/ч, но это движение без GPS, не стоянка.
        let line = [pt(0, 0), pt(3600, 800)]
        #expect(stepStrokes(line) == [.gap])
        #expect(trackStops([line]).isEmpty)
    }

    @Test func longStepStopRadiusFollowsAccuracy() {
        #expect(stepStrokes([pt(0, 0), pt(600, 40)]) == [.band(.stop)])
        #expect(stepStrokes([pt(0, 0), pt(600, 100)]) == [.gap])
        #expect(stepStrokes([pt(0, 0, acc: 60), pt(600, 100, acc: 60)]) == [.band(.stop)])
        #expect(stepStrokes([pt(0, 0, acc: 400), pt(600, 400, acc: 400)]) == [.gap])
    }

    @Test func longStepBoundaryIsStrictlyAboveThreeMinutes() {
        #expect(stepStrokes([ptMs(0, 0), ptMs(180_000, 700)]) == [.band(.fast)])
        #expect(stepStrokes([ptMs(0, 0), ptMs(180_001, 700)]) == [.gap])
    }

    // MARK: - speedRuns

    @Test func singleBandIsOneRunWithAllPoints() {
        let line = steady(count: 10, mps: walkMps)
        #expect(speedRuns([line]) == [SpeedRun(stroke: .band(.walk), points: line)])
    }

    @Test func bandChangeSplitsRunsSharingBoundaryPoint() {
        // 7 точек ходьбы (0…90 с), затем 12 точек бега с 105 с.
        let walk = steady(count: 7, mps: walkMps)
        let run = steady(count: 12, startSec: 105, startM: 7 * walkStepM, mps: 3 * walkMps)
        let line = walk + run
        let runs = speedRuns([line])

        #expect(runs.count >= 2)
        #expect(runs.first?.stroke == .band(.walk))
        #expect(runs.last?.stroke == .band(.fast))
        for (lhs, rhs) in zip(runs, runs.dropFirst()) {
            #expect(lhs.stroke != rhs.stroke)
            #expect(lhs.points.last == rhs.points.first)
        }
        #expect(runs.first?.points.first == line.first)
        #expect(runs.last?.points.last == line.last)
        #expect(runs.allSatisfy { $0.points.count >= 2 })
    }

    @Test func gapRunSitsBetweenSpeedRuns() {
        let left = steady(count: 7, mps: walkMps)
        let right = steady(count: 7, startSec: 90 + 600, startM: 6 * walkStepM + 700, mps: walkMps)
        let runs = speedRuns([left + right])

        #expect(runs.map(\.stroke) == [.band(.walk), .gap, .band(.walk)])
        #expect(runs[1].points == [left.last!, right.first!])
    }

    @Test func linesNeverMergeAndOnePointLinesGiveNoRuns() {
        let a = steady(count: 5, mps: walkMps)
        let b = steady(count: 5, startSec: 1000, startM: 1000, mps: walkMps)
        let runs = speedRuns([a, [pt(500, 500)], b])
        #expect(runs == [SpeedRun(stroke: .band(.walk), points: a), SpeedRun(stroke: .band(.walk), points: b)])
        #expect(speedRuns([]).isEmpty)
    }

    // MARK: - trackStops

    @Test func restWithoutFixesIsOneStop() {
        // Ходьба, 10 минут без фиксов (телефон стоит), ходьба дальше с того же места.
        let left = steady(count: 7, mps: walkMps)
        let right = steady(count: 7, startSec: 90 + 600, startM: 6 * walkStepM + 5, mps: walkMps)
        let stops = trackStops([left + right])

        #expect(stops.count == 1)
        let stop = stops[0]
        #expect(stop.startMs == 90_000)
        #expect(stop.endMs == 690_000)
        #expect(isClose(stop.lat, (left.last!.lat + right.first!.lat) / 2, tol: 1e-9))
        #expect(isClose(stop.lon, baseLon, tol: 1e-9))
    }

    @Test func slowDriftIsStop() {
        let stops = trackStops([steady(count: 25, mps: 0.5 / 3.6)])
        #expect(stops.count == 1)
        #expect(stops.first?.startMs == 0)
        #expect(stops.first?.endMs == 360_000)
    }

    @Test func steadySlowWalkIsNotStop() {
        #expect(trackStops([steady(count: 41, mps: 1 / 3.6)]).isEmpty)
    }

    @Test func stopNeedsFiveMinutes() {
        #expect(trackStops([[pt(0, 0), pt(299, 2)]]).isEmpty)
        #expect(trackStops([[pt(0, 0), pt(300, 2)]]).count == 1)
        #expect(trackStops([(0..<17).map { i in pt(Int64(i) * 15, 0) }]).isEmpty)   // 4 мин
    }

    @Test func longStepWithDisplacementIsNotStop() {
        #expect(trackStops([[pt(0, 0), pt(600, 700)]]).isEmpty)
    }

    @Test func walkRestWalkWithIrregularNoiseIsOneStop() {
        // 5 мин ходьбы, 8 мин стоим с непериодическим 2D-шумом ±6 м, 5 мин ходьбы.
        let walk1 = steady(count: 21, mps: walkMps)
        let restM = 20 * walkStepM
        let rest = (1...32).map { i in
            let j = jitter(i, 6)
            return pt(300 + Int64(i) * 15, restM + j.north, eastM: j.east)
        }
        let walk2 = steady(count: 21, startSec: 300 + 33 * 15, startM: restM, mps: walkMps)
        let stops = trackStops([walk1 + rest + walk2])

        #expect(stops.count == 1)
        let stop = try! #require(stops.first)
        let minutes = Double(stop.endMs - stop.startMs) / 60_000
        #expect(minutes >= 6 && minutes <= 8.5)
        #expect(stop.startMs >= 240_000 && stop.endMs <= 855_000)
    }

    @Test func twoRestsGiveTwoStops() {
        let rest1 = (0..<33).map { i in pt(Int64(i) * 15, 0) }
        let walk = Array(steady(count: 13, startSec: 480, startM: 0, mps: walkMps).dropFirst())
        let walkEndM = 12 * walkStepM
        let rest2 = (0..<33).map { i in pt(675 + Int64(i) * 15, walkEndM) }
        #expect(trackStops([rest1 + walk + rest2]).count == 2)
    }

    @Test func stopsNeverCrossLines() {
        // По 4 минуты в каждой линии: вместе было бы 8, но линии не склеиваются.
        let a = (0..<17).map { i in pt(Int64(i) * 15, 0) }
        let b = (0..<17).map { i in pt(240 + Int64(i) * 15, 0, seg: "seg2") }
        #expect(trackStops([a, b]).isEmpty)
    }

    // MARK: - formatStopDuration

    @Test func stopDurationFormat() {
        #expect(formatStopDuration(ms: 180_000) == "3 мин")
        #expect(formatStopDuration(ms: 239_999) == "3 мин")
        #expect(formatStopDuration(ms: 59 * 60_000) == "59 мин")
        #expect(formatStopDuration(ms: 60 * 60_000) == "1 ч 00 мин")
        #expect(formatStopDuration(ms: 65 * 60_000) == "1 ч 05 мин")
        #expect(formatStopDuration(ms: 125 * 60_000) == "2 ч 05 мин")
    }

    // MARK: - SpeedTrack

    @Test func speedTrackCombinesRunsAndStops() {
        let lines = [steady(count: 17, mps: 0.5 / 3.6)]
        let track = SpeedTrack(lines: lines)
        #expect(track.runs == speedRuns(lines))
        #expect(track.stops == trackStops(lines))
    }

    @Test func memoRecomputesOnlyForNewLines() {
        let memo = SpeedTrackMemo()
        let lines = [steady(count: 10, mps: walkMps)]
        let first = memo.get(lines: lines)
        #expect(memo.get(lines: lines) == first)
        let other = [steady(count: 17, mps: 0.5 / 3.6)]
        #expect(memo.get(lines: other) == SpeedTrack(lines: other))
        #expect(memo.get(lines: []) == SpeedTrack(lines: []))
    }
}
