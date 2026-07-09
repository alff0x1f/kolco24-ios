//
//  RaceDatesTests.swift
//  kolco24Tests
//
//  Бонус-сьют для `Core/Util/RaceDates.swift`. JVM-зеркала для `DateUtils.kt`
//  нет (`todayIso`/`effectiveEnd` в Kotlin не покрыты юнит-тестами, а
//  `nearestRaceId` зеркалится в `TeamPickerLogicTests`). Здесь — edge-кейсы
//  `effectiveEnd`/`nearestRaceId`/`todayIso`, которых нет в Kotlin.
//
//  Весь сьют — бонус.
//

import Foundation
import Testing
@testable import kolco24

// MARK: - БОНУС-тесты

struct RaceDatesTests {

    private func race(id: Int = 1, date: String, dateEnd: String? = nil) -> Race {
        Race(
            id: id,
            name: "Гонка \(id)",
            slug: "race-\(id)",
            date: date,
            dateEnd: dateEnd,
            place: "Лес",
            regStatus: "open"
        )
    }

    // --- effectiveEnd ---

    @Test func effectiveEndUsesDateEndWhenPresent() {
        #expect(effectiveEnd(race(date: "2026-06-10", dateEnd: "2026-06-15")) == "2026-06-15")
    }

    @Test func effectiveEndFallsBackToDateWhenNil() {
        #expect(effectiveEnd(race(date: "2026-06-10", dateEnd: nil)) == "2026-06-10")
    }

    // --- nearestRaceId edge cases ---

    @Test func nearestOnEmptyIsNil() {
        #expect(nearestRaceId([], today: "2026-06-13") == nil)
    }

    @Test func nearestAllInPastIsNil() {
        let a = race(id: 1, date: "2025-01-01")
        let b = race(id: 2, date: "2025-02-01", dateEnd: "2025-02-03")
        #expect(nearestRaceId([a, b], today: "2026-06-13") == nil)
    }

    @Test func nearestTieReturnsFirstEncountered() {
        // `min(by:)` возвращает первый минимальный — как Kotlin `minByOrNull`.
        let a = race(id: 1, date: "2026-06-15")
        let b = race(id: 2, date: "2026-06-15")
        #expect(nearestRaceId([a, b], today: "2026-06-13") == 1)
        #expect(nearestRaceId([b, a], today: "2026-06-13") == 2)
    }

    @Test func nearestPrefersEarlierStartRegardlessOfListOrder() {
        let later = race(id: 1, date: "2026-07-01")
        let earlier = race(id: 2, date: "2026-06-20")
        #expect(nearestRaceId([later, earlier], today: "2026-06-13") == 2)
        #expect(nearestRaceId([earlier, later], today: "2026-06-13") == 2)
    }

    // --- todayIso ---

    @Test func todayIsoMatchesLocalCalendarDate() {
        // Не завязываемся на TZ раннера: сравниваем с независимой раскладкой того
        // же инстанта через локальный календарь (yyyy-MM-dd).
        let instant = Date(timeIntervalSince1970: 1_781_000_000)
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: instant)
        let expected = String(format: "%04d-%02d-%02d", comps.year!, comps.month!, comps.day!)
        #expect(todayIso(now: instant) == expected)
    }

    @Test func todayIsoIsTenChars() {
        let iso = todayIso(now: Date(timeIntervalSince1970: 0))
        #expect(iso.count == 10)
        #expect(iso.contains("-"))
    }
}
