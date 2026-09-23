//
//  ControlTimeTests.swift
//  kolco24Tests
//
//  iOS-only (Kotlin-источника нет): чистая `controlTimeState` — состояния КВ,
//  правила выбора старта/финиша, округление вниз как на сервере — и форматтер
//  `formatHoursMinutes`.
//

import Testing
@testable import kolco24

struct ControlTimeTests {

    private static let min: Int64 = 60_000
    private static let hour: Int64 = 60 * min
    private static let t0: Int64 = 1_700_000_000_000

    private let legend = [
        Checkpoint(id: 100, raceId: 1, number: 0, cost: nil, type: "start", description: nil),
        Checkpoint(id: 101, raceId: 1, number: 1, cost: 2, type: "kp", description: nil),
        Checkpoint(id: 199, raceId: 1, number: 99, cost: nil, type: "finish", description: nil),
    ]

    private func mark(
        _ id: String,
        cp: Int,
        at takenAt: Int64,
        trusted: Int64? = nil
    ) -> Mark {
        Mark(
            id: id,
            raceId: 1,
            teamId: 7,
            checkpointId: cp,
            checkpointNumber: cp,
            cost: 0,
            method: "nfc",
            cpUid: "UID",
            cpCode: "CODE",
            present: [],
            expectedCount: 0,
            complete: false,
            takenAt: takenAt,
            updatedAt: takenAt,
            trustedTakenAt: trusted
        )
    }

    private func state(_ marks: [Mark], cps: [Checkpoint]? = nil, minutes: Int = 480,
                       now: Int64 = ControlTimeTests.t0) -> ControlTimeState {
        controlTimeState(marks: marks, checkpoints: cps ?? legend, controlMinutes: minutes, nowMs: now)
    }

    // MARK: - Состояния

    @Test func unknown_whenControlTimeNotSet() {
        #expect(state([], minutes: 0) == .unknown)
        #expect(state([mark("s", cp: 100, at: Self.t0)], minutes: 0, now: Self.t0 + Self.hour) == .unknown)
    }

    @Test func notStarted_showsLimit() {
        #expect(state([mark("k", cp: 101, at: Self.t0)]) == .notStarted(limitMs: 8 * Self.hour))
    }

    @Test func running_remaining() {
        let now = Self.t0 + 4 * Self.hour + 33 * Self.min
        #expect(state([mark("s", cp: 100, at: Self.t0)], now: now)
            == .running(remainingMs: 3 * Self.hour + 27 * Self.min))
    }

    @Test func overtime_atAndAfterLimit() {
        let s = [mark("s", cp: 100, at: Self.t0)]
        #expect(state(s, now: Self.t0 + 8 * Self.hour) == .overtime(overMs: 0))
        #expect(state(s, now: Self.t0 + 8 * Self.hour + 12 * Self.min) == .overtime(overMs: 12 * Self.min))
    }

    @Test func finished_withoutOvertime() {
        let marks = [mark("s", cp: 100, at: Self.t0), mark("f", cp: 199, at: Self.t0 + 7 * Self.hour + 48 * Self.min)]
        #expect(state(marks, now: Self.t0 + 20 * Self.hour)
            == .finished(elapsedMs: 7 * Self.hour + 48 * Self.min, overMs: nil))
    }

    @Test func finished_withOvertime() {
        let marks = [mark("s", cp: 100, at: Self.t0), mark("f", cp: 199, at: Self.t0 + 8 * Self.hour + 12 * Self.min)]
        #expect(state(marks) == .finished(elapsedMs: 8 * Self.hour + 12 * Self.min, overMs: 12 * Self.min))
    }

    // MARK: - Правила

    @Test func twoStarts_earliestWins() {
        let marks = [mark("s2", cp: 100, at: Self.t0 + Self.hour), mark("s1", cp: 100, at: Self.t0)]
        #expect(state(marks, now: Self.t0 + 2 * Self.hour) == .running(remainingMs: 6 * Self.hour))
    }

    @Test func finishBeforeStart_ignored() {
        let marks = [mark("f", cp: 199, at: Self.t0 - Self.hour), mark("s", cp: 100, at: Self.t0)]
        #expect(state(marks, now: Self.t0 + Self.hour) == .running(remainingMs: 7 * Self.hour))
    }

    @Test func finishWithoutStart_isNotStarted() {
        #expect(state([mark("f", cp: 199, at: Self.t0)]) == .notStarted(limitMs: 8 * Self.hour))
    }

    @Test func trustedTakenAt_winsOverTakenAt() {
        // wall-время старта на час раньше trusted — считается от trusted.
        let marks = [mark("s", cp: 100, at: Self.t0 - Self.hour, trusted: Self.t0)]
        #expect(state(marks, now: Self.t0 + Self.hour) == .running(remainingMs: 7 * Self.hour))
    }

    @Test func noLegend_isNotStarted() {
        let marks = [mark("s", cp: 100, at: Self.t0), mark("f", cp: 199, at: Self.t0 + Self.hour)]
        #expect(state(marks, cps: []) == .notStarted(limitMs: 8 * Self.hour))
    }

    // MARK: - Округление

    @Test func finish_59sOver_isNotLate() {
        let marks = [mark("s", cp: 100, at: Self.t0), mark("f", cp: 199, at: Self.t0 + 8 * Self.hour + 59_000)]
        #expect(state(marks) == .finished(elapsedMs: 8 * Self.hour + 59_000, overMs: nil))
    }

    @Test func finish_exactly60sOver_isLate() {
        let marks = [mark("s", cp: 100, at: Self.t0), mark("f", cp: 199, at: Self.t0 + 8 * Self.hour + Self.min)]
        #expect(state(marks) == .finished(elapsedMs: 8 * Self.hour + Self.min, overMs: Self.min))
    }

    @Test func finished_withoutControlTime_hasNoOvertime() {
        let marks = [mark("s", cp: 100, at: Self.t0), mark("f", cp: 199, at: Self.t0 + 30 * Self.hour)]
        #expect(state(marks, minutes: 0) == .finished(elapsedMs: 30 * Self.hour, overMs: nil))
    }

    // MARK: - formatHoursMinutes

    @Test func format_hoursMinutes_floorsToMinute() {
        #expect(formatHoursMinutes(0) == "0:00")
        #expect(formatHoursMinutes(59_999) == "0:00")
        #expect(formatHoursMinutes(8 * Self.hour) == "8:00")
        #expect(formatHoursMinutes(3 * Self.hour + 27 * Self.min + 59_000) == "3:27")
        #expect(formatHoursMinutes(12 * Self.min) == "0:12")
    }
}
