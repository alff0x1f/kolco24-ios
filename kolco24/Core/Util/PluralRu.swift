//
//  PluralRu.swift
//  kolco24
//
//  Чистый Android-free русский плюрализатор + производные хелперы счётчиков.
//  Kotlin-источники: `data/PluralRu.kt` (`pluralRu`), `data/track/PointsPlural.kt`
//  (`pointsWord`/`pointsLabel`/`segmentsWord`).
//

import Foundation

/// Русский плюрал по величине `count`:
/// - teens (11..14) → `many` (1 балл vs 11 баллов);
/// - последняя цифра 1 → `one` (1, 21, 41…);
/// - последняя цифра 2..4 → `few` (2, 23, 82…);
/// - иначе (0, 5..20, 25…) → `many`.
func pluralRu(count: Int, one: String, few: String, many: String) -> String {
    let n = count < 0 ? -count : count
    if (11...14).contains(n % 100) { return many }
    switch n % 10 {
    case 1: return one
    case 2, 3, 4: return few
    default: return many
    }
}

/// Просклонённая «точка» для счётчика GPS-фиксов.
func pointsWord(_ count: Int) -> String {
    pluralRu(count: count, one: "точка", few: "точки", many: "точек")
}

/// «N точка/точки/точек».
func pointsLabel(_ count: Int) -> String {
    "\(count) \(pointsWord(count))"
}

/// Просклонённый «сегмент» для счётчика сессий записи.
func segmentsWord(_ count: Int) -> String {
    pluralRu(count: count, one: "сегмент", few: "сегмента", many: "сегментов")
}
