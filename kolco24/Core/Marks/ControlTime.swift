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
    let typeById = Dictionary(checkpoints.map { ($0.id, $0.type) }, uniquingKeysWith: { first, _ in first })

    func times(ofType type: String) -> [Int64] {
        marks.filter { $0.method == "nfc" && typeById[$0.checkpointId] == type }
            .map { $0.trustedTakenAt ?? $0.takenAt }
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
    return "\(hours):" + String(format: "%02d", minutes)
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
