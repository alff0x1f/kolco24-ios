//
//  ControlTime.swift
//  kolco24
//
//  Контрольное время (КВ) команды для ячейки «До КВ» вкладки Отметки. iOS-only —
//  Kotlin-источника нет. Чистая функция: старт/финиш берутся только из своих
//  NFC-отметок команды на КП типа `start`/`finish` (работает офлайн, сразу после скана),
//  «сейчас» передаёт вызывающий (тик `TimelineView`), таймеров здесь нет. Фильтр —
//  как в серверном `_auto_populate_boundary_times` (`apps/mobile/views.py`):
//  `method == "nfc"`, время > 0 (фото-отметки и epoch-0 не считаются).
//
//  Округление вниз до минут везде — как на сервере (`apps/race/results.py`:
//  `duration_min = int(ms/1000/60)`, опоздание, если `duration_min > control_time`).
//

import Foundation

/// Состояние КВ команды.
enum ControlTimeState: Equatable {
    /// КВ не задано (`controlMinutes <= 0`) или категории нет.
    case unknown
    /// Старта ещё нет — показывается само КВ.
    case notStarted(limitMs: Int64)
    /// Стартовали, КВ не вышло — остаток.
    case running(remainingMs: Int64)
    /// КВ вышло, финиша нет — опоздание на текущий момент.
    case overtime(overMs: Int64)
    /// Финишировали: время на дистанции; `overMs` не nil, если опоздание ≥ 1 мин.
    case finished(elapsedMs: Int64, overMs: Int64?)
}

private let msPerMinute: Int64 = 60_000

/// Состояние КВ по отметкам команды. `nowMs` — в той же шкале, что время отметок
/// (`trustedTakenAt ?? takenAt`). Старт = самая ранняя NFC-отметка на КП типа `start`;
/// финиш = самая ранняя NFC-отметка на КП типа `finish` не раньше старта. Без легенды
/// типы неизвестны → старта нет. Абсурдное КВ (переполнение `Int64` в мс) → `.unknown`.
func controlTimeState(
    marks: [Mark],
    checkpoints: [Checkpoint],
    controlMinutes: Int,
    nowMs: Int64
) -> ControlTimeState {
    var typeById: [Int: String] = [:]
    for cp in checkpoints { typeById[cp.id] = cp.type }

    func time(_ m: Mark) -> Int64 { m.trustedTakenAt ?? m.takenAt }
    func times(ofType type: String) -> [Int64] {
        marks.filter { $0.method == "nfc" && typeById[$0.checkpointId] == type }
            .map(time)
            .filter { $0 > 0 }
    }

    let start = times(ofType: "start").min()
    let finish = start.flatMap { s in times(ofType: "finish").filter { $0 >= s }.min() }
    let (limitMs, overflow) = Int64(controlMinutes).multipliedReportingOverflow(by: msPerMinute)

    if let start, let finish {
        let elapsed = finish - start
        // При переполнении limitMs `late` ложно: elapsed в минутах не превзойдёт такое КВ.
        let late = controlMinutes > 0 && elapsed / msPerMinute > Int64(controlMinutes)
        return .finished(elapsedMs: elapsed, overMs: late ? elapsed - limitMs : nil)
    }
    guard controlMinutes > 0, !overflow else { return .unknown }
    guard let start else { return .notStarted(limitMs: limitMs) }

    let elapsed = nowMs - start
    return elapsed < limitMs
        ? .running(remainingMs: limitMs - elapsed)
        : .overtime(overMs: elapsed - limitMs)
}

/// `Ч:ММ` с округлением вниз до минуты (`3 ч 27 мин 59 с` → `3:27`).
/// Отрицательные значения не ожидаются.
func formatHoursMinutes(_ ms: Int64) -> String {
    let totalMinutes = ms / msPerMinute
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    return "\(hours):" + (minutes < 10 ? "0\(minutes)" : "\(minutes)")
}

/// «Сейчас» в trusted-шкале отметок из wall-времени. `skew = wall − trusted`, поэтому при
/// `.skewed` skew вычитается. При `.ok` расхождение ниже порога skew не известно точно и не
/// корректируется (≤ ±1 мин в ячейке — принято); при `.noSync` доверенного времени нет → wall.
func trustedNowMs(wallMs: Int64, clock: ClockStatus) -> Int64 {
    if case .skewed(let skewMs) = clock { return wallMs - skewMs }
    return wallMs
}

/// Подпись/значение/красный ячейки «До КВ» (таблица плана).
func controlTimeDisplay(_ state: ControlTimeState) -> (label: String, value: String, isWarning: Bool) {
    switch state {
    case .unknown:
        return ("До КВ", "—", false)
    case .notStarted(let limitMs):
        return ("КВ", formatHoursMinutes(limitMs), false)
    case .running(let remainingMs):
        return ("До КВ", formatHoursMinutes(remainingMs), false)
    case .overtime(let overMs):
        return ("Опоздание", "+" + formatHoursMinutes(overMs), true)
    case .finished(let elapsedMs, let overMs):
        return ("Время", formatHoursMinutes(elapsedMs), overMs != nil)
    }
}
