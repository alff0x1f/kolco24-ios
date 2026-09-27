//
//  TrackLines.swift
//  kolco24
//
//  Чистый read-time фильтр выбросов GPS-трека. Порт `trackLines` из `data/track/TrackModels.kt`
//  (Android #95, план `20260926-track-spike-filter.md`). Заменяет прежний порог `filterPoints`
//  (accuracy > 50 м), который выкидывал годные 60–100 м фиксы и рисовал длинные прямые.
//
//  Возвращает **линии**, а не плоский список: каждый переход внутри линии достижим, между линиями
//  ничего не рисуется. Карта и GPX рисуют линии. В БД и на сервер уходит сырой трек — фильтр только
//  для отображения/экспорта.
//

import Foundation

/// Фиксы с точностью хуже этого (метры) всегда отбрасываются фильтром ``trackLines(_:filter:)``.
private let HARD_CAP_ACCURACY_M: Float = 500

/// Предельная правдоподобная скорость (~50 км/ч — велосипед на спуске) для теста достижимости.
private let MAX_SPEED_MPS: Double = 14

/// Цепочка из не более чем стольких точек **и** короче ``SHORT_CHAIN_MAX_DURATION_MS`` — короткая.
private let SHORT_CHAIN_MAX_POINTS = 3

/// Цепочка длительностью от этого значения — никогда не короткая, сколько бы в ней ни было точек.
private let SHORT_CHAIN_MAX_DURATION_MS: Int64 = 60_000

/// Короткий хвост отбрасывается, только если его медианная точность хуже во столько раз.
private let TAIL_ACCURACY_RATIO: Float = 3

/// Пол (метры) опорной медианы в хвостовом правиле — иначе длинная цепочка с точностью 0 давала бы
/// `>= 3 × 0` и отбрасывала любой короткий хвост.
private let TAIL_REFERENCE_MIN_ACCURACY_M: Float = 1

private let EARTH_RADIUS_M = 6_371_000.0

/// Расстояние по большому кругу (метры) между двумя WGS84-координатами (haversine, сферическая Земля).
func haversineMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
    let dLat = (lat2 - lat1) * .pi / 180
    let dLon = (lon2 - lon1) * .pi / 180
    let sinLat = sin(dLat / 2)
    let sinLon = sin(dLon / 2)
    let h = sinLat * sinLat + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sinLon * sinLon
    return 2 * EARTH_RADIUS_M * asin(sqrt(min(max(h, 0), 1)))
}

/// Мог ли девайс переместиться из [a] в [b]? Дистанция уменьшается на лучшую из двух точностей
/// (допуск на шум), интервал времени — не меньше 1 с, скорость не должна превышать
/// ``MAX_SPEED_MPS`` (включительно). Время — ``trackPointTimeMs(_:)`` (`trustedMs ?? wallMs`).
func isReachable(_ a: TrackPoint, _ b: TrackPoint) -> Bool {
    let d = haversineMeters(lat1: a.lat, lon1: a.lon, lat2: b.lat, lon2: b.lon)
    let dtMs = max(abs(trackPointTimeMs(b) - trackPointTimeMs(a)), 1000)
    let excess = max(0, d - Double(min(a.accuracy, b.accuracy)))
    return excess / (Double(dtMs) / 1000) <= MAX_SPEED_MPS
}

/// Цепочка короткая (кандидат на удаление): не более ``SHORT_CHAIN_MAX_POINTS`` точек и короче
/// ``SHORT_CHAIN_MAX_DURATION_MS``. Одна точка всегда короткая.
func isShortChain(_ chain: [TrackPoint]) -> Bool {
    guard let first = chain.first, let last = chain.last else { return true }
    return chain.count <= SHORT_CHAIN_MAX_POINTS &&
        trackPointTimeMs(last) - trackPointTimeMs(first) < SHORT_CHAIN_MAX_DURATION_MS
}

private func medianAccuracy(_ chain: [TrackPoint]) -> Float {
    let sorted = chain.map(\.accuracy).sorted()
    let mid = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

/// Read-time фильтр выбросов: делит уже отсортированные (``sortedTrackPoints(_:)``) [points] на
/// рисуемые **линии**. Каждый переход внутри линии достижим (``isReachable(_:_:)``), между линиями
/// ничего не рисуется.
///
/// [filter] `false` («Все точки»): только разбиение на последовательные раны `segmentId`.
/// [filter] `true`:
/// 1. отбросить фиксы с точностью хуже ``HARD_CAP_ACCURACY_M``;
/// 2. разбить на последовательные раны `segmentId` — линии никогда не пересекают раны;
/// 3. порезать ран на цепочки по каждому недостижимому шагу; одна цепочка — одна линия как есть;
/// 4. пройти цепочки слева направо. **Голова** отбрасывается, если она короткая, а следующая цепочка
///    длинная (длинная цепочка доказывает, что реальный трек в другом месте). Короткая **внутренняя**
///    цепочка отбрасывается, если её обход достижим из последней принятой точки. Короткий **хвост**
///    отбрасывается только после принятой длинной цепочки, чья медианная точность минимум в
///    ``TAIL_ACCURACY_RATIO`` раз лучше (с полом ``TAIL_REFERENCE_MIN_ACCURACY_M``) — иначе живой
///    хвост остаётся виден (следующий фикс превратит его во внутреннюю цепочку с проверкой обхода);
/// 5. принятая цепочка присоединяется к текущей линии, если достижима из её последней точки, иначе
///    начинает новую.
///
/// Точность не решает, какая точка верна (это оценка 68%): она лишь питает жёсткий порог, допуск на
/// шум в достижимости и хвостовое правило. Один детерминированный проход. Принятые промахи (редкие;
/// скачок никогда не рисуется, остаётся лишь лишняя короткая линия):
/// - два взаимно недостижимых выброса подряд между длинными цепочками (`L X Y R`) остаются оба, каждый
///   своей линией — ни один обход (`L→Y`, `X→R`) не достижим;
/// - кластер выбросов, разбитый на две короткие цепочки в голове или хвосте, выживает.
/// Линии никогда не пустые.
func trackLines(_ points: [TrackPoint], filter: Bool) -> [[TrackPoint]] {
    let input = filter ? points.filter { $0.accuracy <= HARD_CAP_ACCURACY_M } : points
    let runs = splitWhen(input) { $0.segmentId != $1.segmentId }
    guard filter else { return runs }
    return runs.flatMap(runLines)
}

/// Линии одного рана `segmentId` (шаги 3–5 ``trackLines(_:filter:)``).
private func runLines(_ run: [TrackPoint]) -> [[TrackPoint]] {
    let chains = splitWhen(run) { !isReachable($0, $1) }
    if chains.count == 1 { return chains }
    var lines: [[TrackPoint]] = []
    var prevKeptLong = false
    for (i, chain) in chains.enumerated() {
        let short = isShortChain(chain)
        let drop: Bool
        if i == 0 {
            drop = short && !isShortChain(chains[1])
        } else if !short {
            drop = false
        } else if i < chains.count - 1 {
            drop = lines.last?.last.map { isReachable($0, chains[i + 1][0]) } ?? false
        } else {
            drop = prevKeptLong &&
                medianAccuracy(chain) >=
                TAIL_ACCURACY_RATIO * max(medianAccuracy(chains[i - 1]), TAIL_REFERENCE_MIN_ACCURACY_M)
        }
        prevKeptLong = !drop && !short
        if drop { continue }
        if let last = lines.last?.last, isReachable(last, chain[0]) {
            lines[lines.count - 1].append(contentsOf: chain)
        } else {
            lines.append(chain)
        }
    }
    return lines
}

/// Делит [items] на непустые последовательные раны, разрезая между соседями, где [cut] — `true`.
private func splitWhen<T>(_ items: [T], cut: (T, T) -> Bool) -> [[T]] {
    guard let head = items.first else { return [] }
    var out: [[T]] = [[head]]
    for i in 1..<items.count {
        if cut(items[i - 1], items[i]) {
            out.append([items[i]])
        } else {
            out[out.count - 1].append(items[i])
        }
    }
    return out
}

/// Отфильтрованный трек для отображения/экспорта: линии ``trackLines(_:filter:)`` над
/// reboot-safe отсортированными точками, их плоский вид и число скрытых фильтром сырых точек.
struct FilteredTrack: Equatable {
    let lines: [[TrackPoint]]
    let points: [TrackPoint]
    /// Сырые минус показанные. Всегда 0 при «Все точки».
    let hiddenCount: Int

    static let empty = FilteredTrack(raw: [], showAllPoints: true)

    init(raw: [TrackPoint], showAllPoints: Bool) {
        lines = trackLines(sortedTrackPoints(raw), filter: !showAllPoints)
        points = lines.flatMap { $0 }
        hiddenCount = raw.count - points.count
    }
}

/// Мемо ``FilteredTrack`` для computed-свойств `@Observable`-моделей: фильтр пересчитывается, только
/// когда сменились сырые точки или режим. Сравнение массивов дешёвое — у `Array.==` есть fast path по
/// общему буферу, а модель отдаёт один и тот же массив до новой эмиссии.
final class FilteredTrackMemo {
    private var raw: [TrackPoint] = []
    private var showAllPoints = true
    private var cached = FilteredTrack.empty

    func get(raw: [TrackPoint], showAllPoints: Bool) -> FilteredTrack {
        if showAllPoints == self.showAllPoints, raw == self.raw { return cached }
        self.raw = raw
        self.showAllPoints = showAllPoints
        cached = FilteredTrack(raw: raw, showAllPoints: showAllPoints)
        return cached
    }
}
