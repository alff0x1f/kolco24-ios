//
//  PluralRuTests.swift
//  kolco24Tests
//
//  Зеркало `data/track/PointsPluralTest.kt` (12 кейсов) 1:1.
//

import Testing
@testable import kolco24

struct PluralRuTests {

    @Test func word_lastDigitOne_isTochka() {
        #expect(pointsWord(1) == "точка")
        #expect(pointsWord(21) == "точка")
        #expect(pointsWord(41) == "точка")
        #expect(pointsWord(101) == "точка")
    }

    @Test func word_lastDigitTwoToFour_isTochki() {
        #expect(pointsWord(2) == "точки")
        #expect(pointsWord(3) == "точки")
        #expect(pointsWord(4) == "точки")
        #expect(pointsWord(22) == "точки")
        #expect(pointsWord(44) == "точки")
    }

    @Test func word_zeroAndFiveToTwenty_isTochek() {
        #expect(pointsWord(0) == "точек")
        #expect(pointsWord(5) == "точек")
        #expect(pointsWord(20) == "точек")
        #expect(pointsWord(100) == "точек")
    }

    @Test func word_teens_areTochek() {
        #expect(pointsWord(11) == "точек")
        #expect(pointsWord(12) == "точек")
        #expect(pointsWord(13) == "точек")
        #expect(pointsWord(14) == "точек")
        #expect(pointsWord(111) == "точек")
        #expect(pointsWord(112) == "точек")
    }

    @Test func word_negative_usesMagnitude() {
        #expect(pointsWord(-1) == "точка")
        #expect(pointsWord(-11) == "точек")
    }

    @Test func label_joinsCountAndWord() {
        #expect(pointsLabel(1) == "1 точка")
        #expect(pointsLabel(2) == "2 точки")
        #expect(pointsLabel(41) == "41 точка")
        #expect(pointsLabel(82) == "82 точки")
        #expect(pointsLabel(0) == "0 точек")
    }

    @Test func segmentsWord_declinesByCount() {
        #expect(segmentsWord(1) == "сегмент")
        #expect(segmentsWord(21) == "сегмент")
        #expect(segmentsWord(2) == "сегмента")
        #expect(segmentsWord(3) == "сегмента")
        #expect(segmentsWord(4) == "сегмента")
        #expect(segmentsWord(0) == "сегментов")
        #expect(segmentsWord(5) == "сегментов")
        #expect(segmentsWord(11) == "сегментов")
        #expect(segmentsWord(13) == "сегментов")
    }

    @Test func relativeTime_underMinute_isJustNow() {
        #expect(relativeTimeRu(atWallMs: 0, nowMs: 0) == "только что")
        #expect(relativeTimeRu(atWallMs: 0, nowMs: 59_000) == "только что")
        #expect(relativeTimeRu(atWallMs: 0, nowMs: 59_999) == "только что")
    }

    @Test func relativeTime_minutes() {
        #expect(relativeTimeRu(atWallMs: 0, nowMs: 60_000) == "1 мин назад")
        #expect(relativeTimeRu(atWallMs: 0, nowMs: 120_000) == "2 мин назад")
        #expect(relativeTimeRu(atWallMs: 0, nowMs: 59 * 60_000) == "59 мин назад")
    }

    @Test func relativeTime_hours() {
        #expect(relativeTimeRu(atWallMs: 0, nowMs: 3_600_000) == "1 ч назад")
        #expect(relativeTimeRu(atWallMs: 0, nowMs: 2 * 3_600_000) == "2 ч назад")
    }

    @Test func relativeTime_negativeDelta_isJustNow() {
        #expect(relativeTimeRu(atWallMs: 120_000, nowMs: 0) == "только что")
    }

    @Test func relativeTime_boundariesRollOver() {
        // 59 999 ms всё ещё под минуту, 60 000 ms перекатывается в «1 мин назад»
        #expect(relativeTimeRu(atWallMs: 0, nowMs: 59_999) == "только что")
        #expect(relativeTimeRu(atWallMs: 0, nowMs: 60_000) == "1 мин назад")
        // одна мс до часа — всё ещё минуты; ровно час перекатывается в «1 ч назад»
        #expect(relativeTimeRu(atWallMs: 0, nowMs: 3_599_999) == "59 мин назад")
        #expect(relativeTimeRu(atWallMs: 0, nowMs: 3_600_000) == "1 ч назад")
    }
}
