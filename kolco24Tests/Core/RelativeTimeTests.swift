//
//  RelativeTimeTests.swift
//  kolco24Tests
//

import Testing
@testable import kolco24

struct RelativeTimeTests {

    @Test func relativeTime_underMinute_isJustNow() {
        #expect(relativeTimeLabel(atWallMs: 0, nowMs: 0) == "только что")
        #expect(relativeTimeLabel(atWallMs: 0, nowMs: 59_000) == "только что")
        #expect(relativeTimeLabel(atWallMs: 0, nowMs: 59_999) == "только что")
    }

    @Test func relativeTime_minutes() {
        #expect(relativeTimeLabel(atWallMs: 0, nowMs: 60_000) == "1 мин назад")
        #expect(relativeTimeLabel(atWallMs: 0, nowMs: 120_000) == "2 мин назад")
        #expect(relativeTimeLabel(atWallMs: 0, nowMs: 59 * 60_000) == "59 мин назад")
    }

    @Test func relativeTime_hours() {
        #expect(relativeTimeLabel(atWallMs: 0, nowMs: 3_600_000) == "1 ч назад")
        #expect(relativeTimeLabel(atWallMs: 0, nowMs: 2 * 3_600_000) == "2 ч назад")
    }

    @Test func relativeTime_negativeDelta_isJustNow() {
        #expect(relativeTimeLabel(atWallMs: 120_000, nowMs: 0) == "только что")
    }

    @Test func relativeTime_boundariesRollOver() {
        // 59 999 ms всё ещё под минуту, 60 000 ms перекатывается в «1 мин назад»
        #expect(relativeTimeLabel(atWallMs: 0, nowMs: 59_999) == "только что")
        #expect(relativeTimeLabel(atWallMs: 0, nowMs: 60_000) == "1 мин назад")
        // одна мс до часа — всё ещё минуты; ровно час перекатывается в «1 ч назад»
        #expect(relativeTimeLabel(atWallMs: 0, nowMs: 3_599_999) == "59 мин назад")
        #expect(relativeTimeLabel(atWallMs: 0, nowMs: 3_600_000) == "1 ч назад")
    }

    @Test func englishLabels() {
        #expect(en(.uploadLastSentJustNow) == "just now")
        #expect(en(.uploadLastSentMinutesAgo(5)) == "5 min ago")
        #expect(en(.uploadLastSentHoursAgo(2)) == "2 h ago")
    }
}
