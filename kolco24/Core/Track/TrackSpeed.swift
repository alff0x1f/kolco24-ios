//
//  TrackSpeed.swift
//  kolco24
//
//  Чистая раскраска трека по скорости (план `20260927-track-speed-colors.md`). Работает поверх линий
//  фильтра выбросов (`trackLines`), только для отображения — в БД и на сервер трек уходит сырым.
//
//  Скорость шага — прямое расстояние между концами окна ~90 с вокруг шага / длительность окна. При записи
//  раз в 15 с шаг пешехода (~17 м) сравним с шумом GPS, поэтому скорость «от точки к точке» бесполезна;
//  сумма пути по окну копила бы шум на каждом шаге (стоящий телефон «шёл» бы 3 км/ч).
//

import Foundation

/// Целевая длительность окна скорости шага.
let SPEED_WINDOW_MS: Int64 = 90_000

/// Шаг длиннее этого — «длинный»: окно через него не растёт, он оценивается по своей скорости.
let SPEED_GAP_MS: Int64 = 180_000

/// Нижние границы диапазонов `slow`, `walk`, `brisk`, `fast` (км/ч, включительно).
let SPEED_BAND_LIMITS_KMH: [Double] = [1, 3, 5, 7]

/// Диапазон скорости для пешего рогейна с рюкзаком.
enum SpeedBand: Int, CaseIterable, Equatable {
    /// < 1 км/ч — стоянка, поиск КП на месте.
    case stop
    /// 1–3 км/ч — бурелом, болото, крутой подъём.
    case slow
    /// 3–5 км/ч — шаг по пересечёнке.
    case walk
    /// 5–7 км/ч — быстрый шаг по дороге.
    case brisk
    /// ≥ 7 км/ч — бег, спуск, велосипед.
    case fast
}

func speedBand(kmh: Double) -> SpeedBand {
    let index = SPEED_BAND_LIMITS_KMH.lastIndex { kmh >= $0 }.map { $0 + 1 } ?? 0
    return SpeedBand(rawValue: index) ?? .fast
}

/// Подпись диапазона в легенде карты: «<1», «1–3», …, «7+» (км/ч).
func speedBandLegendLabel(_ band: SpeedBand) -> String {
    let limits = SPEED_BAND_LIMITS_KMH.map { String(Int($0)) }
    let i = band.rawValue
    if i == 0 { return "<\(limits[0])" }
    if i == limits.count { return "\(limits[i - 1])+" }
    return "\(limits[i - 1])–\(limits[i])"
}

private func stepDistanceMeters(_ a: TrackPoint, _ b: TrackPoint) -> Double {
    haversineMeters(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon)
}

/// Скорость (м/с) между [a] и [b] с полом времени 1 с.
private func averageSpeedMps(_ a: TrackPoint, _ b: TrackPoint) -> Double {
    let dtMs = max(trackPointTimeMs(b) - trackPointTimeMs(a), 1000)
    return stepDistanceMeters(a, b) / (Double(dtMs) / 1000)
}

/// Скорости (м/с) шагов линии, `line.count - 1` значений. Длинный шаг (> ``SPEED_GAP_MS``) — своя
/// скорость. Обычный шаг — окно от него растёт попеременно влево и вправо (через длинный шаг не растёт;
/// упёршись с одной стороны, растёт с другой), пока не наберёт ``SPEED_WINDOW_MS`` или не кончится
/// линия.
func stepSpeedsMps(_ line: [TrackPoint]) -> [Double] {
    guard line.count >= 2 else { return [] }
    let times = line.map(trackPointTimeMs)
    let last = line.count - 1
    let isLong = (0..<last).map { times[$0 + 1] - times[$0] > SPEED_GAP_MS }

    return (0..<last).map { k in
        if isLong[k] { return averageSpeedMps(line[k], line[k + 1]) }
        var a = k, b = k + 1
        var growLeft = true
        while times[b] - times[a] < SPEED_WINDOW_MS {
            let canLeft = a > 0 && !isLong[a - 1]
            let canRight = b < last && !isLong[b]
            if !canLeft && !canRight { break }
            if (growLeft && canLeft) || !canRight {
                a -= 1
            } else {
                b += 1
            }
            growLeft.toggle()
        }
        return averageSpeedMps(line[a], line[b])
    }
}

/// Как рисовать шаг трека.
enum SpeedStroke: Equatable {
    case band(SpeedBand)
    /// Длинный шаг в движении (дыра GPS) — средняя скорость по нему выглядела бы медленной ходьбой.
    case gap
}

/// Длинный шаг — стоянка, только если его концы не дальше `max(этого, сумма точностей)` метров…
let LONG_STEP_STOP_MIN_RADIUS_M: Double = 50

/// …но не дальше этого: грубые фиксы не должны превращать час движения без GPS в стоянку.
let LONG_STEP_STOP_MAX_RADIUS_M: Double = 150

/// Штрихи шагов линии, `line.count - 1` значений. Обычный шаг — диапазон его скорости по окну. Длинный
/// шаг — стоянка, если его концы рядом (на iOS стоящий телефон фиксов не даёт: `isStationary`
/// пропускается), иначе ``SpeedStroke/gap``. Порог по расстоянию, а не по средней скорости: час без
/// GPS в движении с концами в 800 м дал бы 0,8 км/ч — ложную «стоянку 1 ч».
func stepStrokes(_ line: [TrackPoint]) -> [SpeedStroke] {
    let speeds = stepSpeedsMps(line)
    return speeds.indices.map { k in
        let a = line[k], b = line[k + 1]
        guard trackPointTimeMs(b) - trackPointTimeMs(a) > SPEED_GAP_MS else {
            return .band(speedBand(kmh: speeds[k] * 3.6))
        }
        let radius = min(
            max(LONG_STEP_STOP_MIN_RADIUS_M, Double(a.accuracy) + Double(b.accuracy)),
            LONG_STEP_STOP_MAX_RADIUS_M
        )
        return stepDistanceMeters(a, b) <= radius ? .band(.stop) : .gap
    }
}

/// Ран подряд идущих шагов с одним штрихом. Соседние раны делят граничную точку.
struct SpeedRun: Equatable {
    let stroke: SpeedStroke
    /// Не меньше 2 точек.
    let points: [TrackPoint]
}

/// Раны штрихов по всем линиям. Раны не пересекают линии; линии из одной точки ранов не дают.
func speedRuns(_ lines: [[TrackPoint]]) -> [SpeedRun] {
    lines.flatMap { line in speedRuns(line: line, strokes: stepStrokes(line)) }
}

private func speedRuns(line: [TrackPoint], strokes: [SpeedStroke]) -> [SpeedRun] {
    var runs: [SpeedRun] = []
    var start = 0
    for k in strokes.indices where k == strokes.count - 1 || strokes[k + 1] != strokes[k] {
        runs.append(SpeedRun(stroke: strokes[k], points: Array(line[start...(k + 1)])))
        start = k + 1
    }
    return runs
}

/// Стоянка короче этого на карте не отмечается.
let STOP_MIN_DURATION_MS: Int64 = 180_000

/// Стоянка: центроид точек и время первой/последней точки.
struct TrackStop: Equatable {
    let lat: Double
    let lon: Double
    let startMs: Int64
    let endMs: Int64
}

/// Стоянки по всем линиям: каждый ран ``SpeedStroke/band(_:)`` `.stop` не короче
/// ``STOP_MIN_DURATION_MS``. Маркеры стоянок всегда совпадают с раскраской; линии не пересекают.
func trackStops(_ lines: [[TrackPoint]]) -> [TrackStop] {
    lines.flatMap { line in trackStops(runs: speedRuns(line: line, strokes: stepStrokes(line))) }
}

private func trackStops(runs: [SpeedRun]) -> [TrackStop] {
    runs.compactMap { run in
        guard run.stroke == .band(.stop), let first = run.points.first, let last = run.points.last else {
            return nil
        }
        let startMs = trackPointTimeMs(first)
        let endMs = trackPointTimeMs(last)
        guard endMs - startMs >= STOP_MIN_DURATION_MS else { return nil }
        let count = Double(run.points.count)
        return TrackStop(
            lat: run.points.reduce(0) { $0 + $1.lat } / count,
            lon: run.points.reduce(0) { $0 + $1.lon } / count,
            startMs: startMs,
            endMs: endMs
        )
    }
}

/// «3 мин», «59 мин», «1 ч 05 мин» — минуты вниз.
func formatStopDuration(ms: Int64) -> String {
    let minutes = ms / 60_000
    guard minutes >= 60 else { return "\(minutes) мин" }
    return "\(minutes / 60) ч " + String(format: "%02d мин", minutes % 60)
}

/// Раскраска трека: раны штрихов и стоянки (штрихи считаются один раз).
struct SpeedTrack: Equatable {
    let runs: [SpeedRun]
    let stops: [TrackStop]

    init(lines: [[TrackPoint]]) {
        let perLine = lines.map { line in speedRuns(line: line, strokes: stepStrokes(line)) }
        runs = perLine.flatMap { $0 }
        stops = perLine.flatMap { trackStops(runs: $0) }
    }
}

/// Мемо ``SpeedTrack`` для computed-свойств модели — как ``FilteredTrackMemo``: `FilteredTrackMemo`
/// отдаёт один и тот же массив линий, так что `==` срабатывает по общему буферу.
final class SpeedTrackMemo {
    private var lines: [[TrackPoint]] = []
    private var cached = SpeedTrack(lines: [])

    func get(lines: [[TrackPoint]]) -> SpeedTrack {
        if lines == self.lines { return cached }
        self.lines = lines
        cached = SpeedTrack(lines: lines)
        return cached
    }
}
