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
}
