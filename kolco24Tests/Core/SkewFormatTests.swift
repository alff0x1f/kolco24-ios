//
//  SkewFormatTests.swift
//  kolco24Tests
//
//  Зеркало ClockWarningBannerTest.kt — 5 кейсов `formatSkewMinutes` (имена 1:1):
//  округление по модулю в Double, оба знака схлопываются в величину, Int64.min не ловушка.
//

import Foundation
import Testing
@testable import kolco24

struct SkewFormatTests {

    @Test
    func roundsHalfUp() {
        // 150_000 ms = ровно 2.5 мин → округляется вверх до 3 (half-up семантика).
        // 149_999 ms = 2.4999... мин → округляется вниз до 2.
        #expect(formatSkewMinutes(150_000) == "3 мин")
        #expect(formatSkewMinutes(149_999) == "2 мин")
    }

    @Test
    func bothSignsCollapseToMagnitude() {
        // Медленные часы дают отрицательный skew — никогда не «−2 мин».
        #expect(formatSkewMinutes(90_000) == "2 мин")
        #expect(formatSkewMinutes(-90_000) == "2 мин")
    }

    @Test
    func justOverThresholdRoundsToOne() {
        #expect(formatSkewMinutes(60_001) == "1 мин")
        #expect(formatSkewMinutes(-60_001) == "1 мин")
    }

    @Test
    func roundsTowardNearest() {
        // 119_000 ms = 1.983 мин → 2.
        #expect(formatSkewMinutes(119_000) == "2 мин")
    }

    @Test
    func longMinValueDoesNotTrapAndStaysPositive() {
        let result = formatSkewMinutes(Int64.min)
        #expect(!result.hasPrefix("-"))
        #expect(!result.hasPrefix("−"))
    }
}
