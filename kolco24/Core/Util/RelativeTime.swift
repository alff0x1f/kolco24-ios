//
//  RelativeTime.swift
//  kolco24
//

import Foundation

/// Чистая метка относительного времени для строки статуса загрузки: «только что» под минуту,
/// «N мин назад» под час, иначе «N ч назад». Отрицательная дельта (скью часов / будущий штамп)
/// зажимается в 0 → «только что».
func relativeTimeLabel(atWallMs: Int64, nowMs: Int64) -> String {
    let seconds = max(nowMs - atWallMs, 0) / 1000
    switch seconds {
    case ..<60: return String(localized: .uploadLastSentJustNow)
    case ..<3600: return String(localized: .uploadLastSentMinutesAgo(Int(seconds / 60)))
    default: return String(localized: .uploadLastSentHoursAgo(Int(seconds / 3600)))
    }
}
