//
//  ChipCheckLogicTests.swift
//  kolco24Tests
//
//  Зеркало `ui/admin/ChipCheckModelTest.kt` → `Core/Admin/ChipCheckLogic` (этап 10). Имена кейсов 1:1.
//  `classifyChipCheck` порядок веток (noCode → unknownChip → inconsistent → ok) + `changedNibbles`.
//

import Foundation
import Testing
@testable import kolco24

struct ChipCheckLogicTests {

    private func tag(bid: String, point: Int, checkMethod: String = "nfc") -> kolco24.Tag {
        kolco24.Tag(raceId: 1, bid: bid, checkpointId: point, checkMethod: checkMethod)
    }

    private func cp(id: Int, number: Int, cost: Int? = 5, color: String = "") -> Checkpoint {
        Checkpoint(id: id, raceId: 1, number: number, cost: cost, type: "kp", description: nil, color: color)
    }

    @Test func classify_tagAndCheckpointPresent_isOk() {
        let result = classifyChipCheck(
            uid: "0411223344AABB",
            bid: "abc123",
            tag: tag(bid: "abc123", point: 10, checkMethod: "photo"),
            checkpoint: cp(id: 10, number: 7, cost: 8, color: "red"),
            chipsOnKp: 3
        )
        #expect(result == .ok(uid: "0411223344AABB", number: 7, cost: 8, color: .red,
                              bid: "abc123", checkMethod: "photo", chipsOnKp: 3))
    }

    @Test func classify_nullBid_isNoCode() {
        let result = classifyChipCheck(uid: "DEADBEEF", bid: nil, tag: nil, checkpoint: nil, chipsOnKp: 0)
        #expect(result == .noCode(uid: "DEADBEEF"))
    }

    @Test func classify_noMatchingTag_isUnknownChip() {
        let result = classifyChipCheck(uid: "0411223344AABB", bid: "deadbid", tag: nil, checkpoint: nil, chipsOnKp: 0)
        #expect(result == .unknownChip(uid: "0411223344AABB", bid: "deadbid"))
    }

    @Test func classify_tagButNoCheckpoint_isInconsistent() {
        let result = classifyChipCheck(
            uid: "0411223344AABB", bid: "abc123",
            tag: tag(bid: "abc123", point: 99), checkpoint: nil, chipsOnKp: 1
        )
        #expect(result == .inconsistent(uid: "0411223344AABB", bid: "abc123", checkpointId: 99))
    }

    @Test func classify_ok_unknownColorToken_nullColor() {
        let result = classifyChipCheck(
            uid: "UID", bid: "abc123",
            tag: tag(bid: "abc123", point: 10),
            checkpoint: cp(id: 10, number: 1, color: "teal"), chipsOnKp: 1
        )
        guard case let .ok(_, _, _, color, _, _, _) = result else {
            Issue.record("ожидался .ok"); return
        }
        #expect(color == nil)
    }

    @Test func classify_lockedCheckpoint_isOkWithNullCost() {
        let result = classifyChipCheck(
            uid: "0411223344AABB", bid: "abc123",
            tag: tag(bid: "abc123", point: 10),
            checkpoint: cp(id: 10, number: 5, cost: nil), chipsOnKp: 1
        )
        #expect(result == .ok(uid: "0411223344AABB", number: 5, cost: nil, color: nil,
                              bid: "abc123", checkMethod: "nfc", chipsOnKp: 1))
    }

    @Test func classify_nullBid_withNonNullArgs_isNoCode() {
        let result = classifyChipCheck(
            uid: "DEADBEEF", bid: nil,
            tag: tag(bid: "abc", point: 1), checkpoint: cp(id: 1, number: 1), chipsOnKp: 2
        )
        #expect(result == .noCode(uid: "DEADBEEF"))
    }

    @Test func changedNibbles_noPrevious_isEmpty() {
        #expect(changedNibbles(uid: "1DC76063031080", previous: nil) == [])
        #expect(changedNibbles(uid: "1DC76063031080", previous: "") == [])
    }

    @Test func changedNibbles_marksOnlyDifferingPositions() {
        // 1DC7... vs 1D69... differ only at indices 2 and 3.
        #expect(changedNibbles(uid: "1DC76063031080", previous: "1D696063031080") == [2, 3])
    }

    @Test func changedNibbles_identicalUid_isEmpty() {
        #expect(changedNibbles(uid: "1DC76063031080", previous: "1DC76063031080") == [])
    }

    @Test func changedNibbles_longerUid_marksTrailingPositions() {
        #expect(changedNibbles(uid: "1DC780", previous: "1DC7") == [4, 5])
    }
}
