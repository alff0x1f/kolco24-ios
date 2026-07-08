//
//  ScanSessionTests.swift
//  kolco24Tests
//
//  Зеркало `ui/scan/ScanSessionTest.kt` (25 кейсов) 1:1: окно, дедуп, порядок
//  событий, слив буфера, переключение КП, границы истечения окна.
//

import Foundation
import Testing
@testable import kolco24

struct ScanSessionTests {

    private func kp(point: Int = 42, number: Int = 7, cost: Int = 50) -> ScanEvent {
        .kp(checkpointId: point, number: number, cost: cost, cpUid: "04AABBCC", cpCode: "DEADBEEF")
    }

    @Test func kp_onNullSession_fillsCheckpointFields() {
        let s = reduce(session: nil, event: kp(), now: 1_000)!
        #expect(s.checkpointId == 42)
        #expect(s.checkpointNumber == 7)
        #expect(s.cost == 50)
        #expect(s.cpUid == "04AABBCC")
        #expect(s.cpCode == "DEADBEEF")
        #expect(s.present.isEmpty)
        #expect(s.lastScanAt == 1_000)
    }

    @Test func member_afterKp_accumulatesPresent() {
        var s = reduce(session: nil, event: kp(), now: 0)
        s = reduce(session: s, event: .member(numberInTeam: 1), now: 100)
        s = reduce(session: s, event: .member(numberInTeam: 2), now: 200)
        #expect(s!.present == Set([1, 2]))
        #expect(s!.lastScanAt == 200)
    }

    @Test func member_isIdempotent_andDoesNotRefreshWindow() {
        var s = reduce(session: nil, event: kp(), now: 0)
        s = reduce(session: s, event: .member(numberInTeam: 1), now: 100)
        s = reduce(session: s, event: .member(numberInTeam: 1), now: 200)
        #expect(s!.present == Set([1]))
        // Повторный скан уже-present участника НЕ обновляет окно.
        #expect(s!.lastScanAt == 100)
    }

    @Test func member_beforeKp_repeat_doesNotRefreshWindow() {
        var s = reduce(session: nil, event: .member(numberInTeam: 1), now: 100)
        s = reduce(session: s, event: .member(numberInTeam: 1), now: 200)
        #expect(s!.bufferedBeforeKp == Set([1]))
        #expect(s!.lastScanAt == 100)
    }

    @Test func membersBeforeKp_areBuffered_thenDrainedOnKp() {
        var s = reduce(session: nil, event: .member(numberInTeam: 1), now: 0)
        s = reduce(session: s, event: .member(numberInTeam: 2), now: 50)
        #expect(s!.checkpointId == nil)
        #expect(s!.bufferedBeforeKp == Set([1, 2]))
        #expect(s!.present.isEmpty)

        s = reduce(session: s, event: kp(), now: 100)
        #expect(s!.checkpointId == 42)
        #expect(s!.present == Set([1, 2]))
        #expect(s!.bufferedBeforeKp.isEmpty)
        #expect(s!.lastScanAt == 100)
    }

    @Test func completeCondition_presentSupersetOfRoster() {
        let roster: Set<Int> = [1, 2, 3]
        var s = reduce(session: nil, event: kp(), now: 0)
        s = reduce(session: s, event: .member(numberInTeam: 1), now: 10)
        s = reduce(session: s, event: .member(numberInTeam: 2), now: 20)
        #expect(!s!.present.isSuperset(of: roster))
        s = reduce(session: s, event: .member(numberInTeam: 3), now: 30)
        #expect(s!.present.isSuperset(of: roster))
    }

    @Test func unboundChip_doesNotAdvanceWindow() {
        let before = reduce(session: nil, event: kp(), now: 1_000)
        let after = reduce(session: before, event: .unboundChip, now: 5_000)
        #expect(before == after)
        #expect(after!.lastScanAt == 1_000)
    }

    @Test func badKp_doesNotAdvanceWindow() {
        let before = reduce(session: nil, event: kp(), now: 1_000)
        let after = reduce(session: before, event: .badKp(reason: "чужой"), now: 5_000)
        #expect(before == after)
        #expect(after!.lastScanAt == 1_000)
    }

    @Test func badKp_onNullSession_staysNull() {
        #expect(reduce(session: nil, event: .badKp(reason: "чужой"), now: 1_000) == nil)
        #expect(reduce(session: nil, event: .unboundChip, now: 1_000) == nil)
    }

    @Test func member_beforeKp_onNullSession_startsBufferingSession() {
        let s = reduce(session: nil, event: .member(numberInTeam: 5), now: 42)
        #expect(s!.checkpointId == nil)
        #expect(s!.bufferedBeforeKp == Set([5]))
        #expect(s!.lastScanAt == 42)
    }

    @Test func kp_repeatScan_preservesPresentAndUpdatesWindow() {
        var s = reduce(session: nil, event: kp(), now: 0)
        s = reduce(session: s, event: .member(numberInTeam: 1), now: 100)
        s = reduce(session: s, event: .member(numberInTeam: 2), now: 200)
        // Повторный скан того же КП — участники сохраняются, окно перештамповано.
        s = reduce(session: s, event: kp(), now: 300)
        #expect(s!.checkpointId == 42)
        #expect(s!.present == Set([1, 2]))
        #expect(s!.lastScanAt == 300)
    }

    @Test func isComplete_kpAndFullRoster_isTrue() {
        var s = reduce(session: nil, event: kp(), now: 0)
        s = reduce(session: s, event: .member(numberInTeam: 1), now: 10)
        s = reduce(session: s, event: .member(numberInTeam: 2), now: 20)
        s = reduce(session: s, event: .member(numberInTeam: 3), now: 30)
        #expect(isComplete(session: s, rosterSize: 3))
    }

    @Test func isComplete_nullSession_isFalse() {
        #expect(!isComplete(session: nil, rosterSize: 3))
    }

    @Test func isComplete_noKp_onlyBuffered_isFalse() {
        var s = reduce(session: nil, event: .member(numberInTeam: 1), now: 0)
        s = reduce(session: s, event: .member(numberInTeam: 2), now: 10)
        s = reduce(session: s, event: .member(numberInTeam: 3), now: 20)
        // КП ещё не сканирован — участники в буфере, present пуст, не complete.
        #expect(!isComplete(session: s, rosterSize: 3))
    }

    @Test func isComplete_partialRoster_isFalse() {
        var s = reduce(session: nil, event: kp(), now: 0)
        s = reduce(session: s, event: .member(numberInTeam: 1), now: 10)
        s = reduce(session: s, event: .member(numberInTeam: 2), now: 20)
        #expect(!isComplete(session: s, rosterSize: 3))
    }

    @Test func isComplete_rosterZero_isFalse() {
        let s = reduce(session: nil, event: kp(), now: 0)
        #expect(!isComplete(session: s, rosterSize: 0))
    }

    @Test func isComplete_presentLargerThanRoster_isTrue() {
        var s = reduce(session: nil, event: kp(), now: 0)
        s = reduce(session: s, event: .member(numberInTeam: 1), now: 10)
        s = reduce(session: s, event: .member(numberInTeam: 2), now: 20)
        s = reduce(session: s, event: .member(numberInTeam: 3), now: 30)
        #expect(isComplete(session: s, rosterSize: 2))
    }

    @Test func isComplete_allBufferedThenKp_isTrue() {
        // Участники сканируются до чипа КП — попадают в bufferedBeforeKp, затем
        // сливаются в present при скане КП. isComplete должно быть true сразу.
        var s = reduce(session: nil, event: .member(numberInTeam: 1), now: 0)
        s = reduce(session: s, event: .member(numberInTeam: 2), now: 10)
        s = reduce(session: s, event: .member(numberInTeam: 3), now: 20)
        s = reduce(session: s, event: kp(), now: 30)
        #expect(isComplete(session: s, rosterSize: 3))
    }

    @Test func isComplete_afterKpSwitch_isFalse() {
        // Переключение на другой КП сбрасывает present в пустой; isComplete → false.
        var s = reduce(session: nil, event: kp(), now: 0)
        s = reduce(session: s, event: .member(numberInTeam: 1), now: 10)
        s = reduce(session: s, event: .member(numberInTeam: 2), now: 20)
        let kpB = ScanEvent.kp(checkpointId: 99, number: 12, cost: 80, cpUid: "04BBBBBB", cpCode: "CAFEBABE")
        s = reduce(session: s, event: kpB, now: 30)
        #expect(!isComplete(session: s, rosterSize: 2))
    }

    // --- Window expiry (isWindowExpired) ---

    @Test func windowExpired_nullLastScan_isNeverExpired() {
        #expect(!isWindowExpired(lastScanAt: nil, now: 999_999))
    }

    @Test func windowExpired_belowWindow_isFalse() {
        #expect(!isWindowExpired(lastScanAt: 1_000, now: 1_000 + 19_999))
    }

    @Test func windowExpired_exactlyAtWindow_isTrue() {
        #expect(isWindowExpired(lastScanAt: 1_000, now: 1_000 + 20_000))
    }

    @Test func windowExpired_aboveWindow_isTrue() {
        #expect(isWindowExpired(lastScanAt: 1_000, now: 1_000 + 20_001))
    }

    @Test func windowExpired_zeroLastScan_isLegalMonotonicReading() {
        #expect(!isWindowExpired(lastScanAt: 0, now: 19_999))
        #expect(isWindowExpired(lastScanAt: 0, now: 20_000))
    }

    @Test func kp_switchCP_resetsPresentAndBufferDrains() {
        let kpB = ScanEvent.kp(checkpointId: 99, number: 12, cost: 80, cpUid: "04BBBBBB", cpCode: "CAFEBABE")
        var s = reduce(session: nil, event: kp(), now: 0)
        s = reduce(session: s, event: .member(numberInTeam: 1), now: 100)
        s = reduce(session: s, event: .member(numberInTeam: 2), now: 200)
        // Переключение на другой КП — участники прежнего КП НЕ переносятся.
        s = reduce(session: s, event: kpB, now: 300)
        #expect(s!.checkpointId == 99)
        #expect(s!.present.isEmpty)
        #expect(s!.bufferedBeforeKp.isEmpty)
        #expect(s!.lastScanAt == 300)
    }
}
