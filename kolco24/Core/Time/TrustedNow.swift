//
//  TrustedNow.swift
//  kolco24
//
//  iOS-only (Kotlin-источника нет): перевод wall-«сейчас» в trusted-шкалу по `ClockStatus`.
//  Foundation-only (греп-инвариант `Core/`).
//

import Foundation

/// «Сейчас» в trusted-шкале отметок из wall-времени. `skew = wall − trusted`, поэтому при
/// `.skewed` skew вычитается. При `.ok` расхождение ниже порога skew не известно точно и не
/// корректируется (≤ ±1 мин в ячейке — принято); при `.noSync` доверенного времени нет → wall.
func trustedNowMs(wallMs: Int64, clock: ClockStatus) -> Int64 {
    if case .skewed(let skewMs) = clock { return wallMs - skewMs }
    return wallMs
}
