//
//  SkewFormat.swift
//  kolco24
//
//  Порт 1:1 `formatSkewMinutes` из `ui/common/ClockWarningBanner.kt:31–34` (Android).
//  Foundation-only (греп-инвариант `Core/`).
//

import Foundation

/// Format a wall-vs-trusted skew (ms, signed) as a direction-less «N мин» string.
///
/// Округление **по модулю**: `(abs(Double(skewMs)) / 60_000).rounded()` — round, а не ceil
/// (60_001 → «1 мин», 90_000 → «2 мин» (1.5→2), 119_000 → «2 мин»). Баннер показывается только
/// на `.skewed` (skew всегда `> 60_000`), поэтому round даёт ≥ «1 мин». Текст без направления,
/// поэтому берём модуль (медленные часы дают отрицательный skew — не «−2 мин»); `abs` считается
/// в `Double`, так что `Int64.min` не ловушка.
///
/// Swift `.rounded()` = `.toNearestOrAwayFromZero`; на положительном `abs` эквивалентен
/// Kotlin `Math.round` (half-up), что фиксирует кейс `roundsHalfUp`.
func formatSkewMinutes(_ skewMs: Int64) -> String {
    let minutes = (abs(Double(skewMs)) / 60_000.0).rounded()
    return "\(Int64(minutes)) мин"
}
