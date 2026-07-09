//
//  LegendDisplayTests.swift
//  kolco24Tests
//
//  Зеркало `ui/legend/CheckpointColorTest.kt` (5), `ui/legend/IsScoringTest.kt`
//  (5), `ui/legend/GroupCheckpointsByColorTest.kt` (6) — 1:1, имена кейсов
//  сохранены. Плюс бонус-кейсы детерминированных ширин locked-скелетона
//  (JVM-зеркала нет — логика во вьюхе `LockedCheckpointRow`).
//

import Testing
@testable import kolco24

struct LegendDisplayTests {

    private func cp(
        id: Int = 1,
        number: Int = 1,
        cost: Int? = nil,
        locked: Bool = false,
        color: String = ""
    ) -> Checkpoint {
        Checkpoint(
            id: id,
            raceId: 1,
            number: number,
            cost: cost,
            type: "kp",
            description: "д",
            locked: locked,
            color: color
        )
    }

    // MARK: - CheckpointColorTest (зеркало, 5)

    @Test func knownTokens_mapToEnum() {
        #expect(parseCheckpointColor("red") == .red)
        #expect(parseCheckpointColor("blue") == .blue)
        #expect(parseCheckpointColor("green") == .green)
        #expect(parseCheckpointColor("yellow") == .yellow)
        #expect(parseCheckpointColor("orange") == .orange)
        #expect(parseCheckpointColor("purple") == .purple)
    }

    @Test func emptyToken_isNull() {
        #expect(parseCheckpointColor("") == nil)
        #expect(parseCheckpointColor("   ") == nil)
    }

    @Test func unknownToken_isNull() {
        #expect(parseCheckpointColor("teal") == nil)
        #expect(parseCheckpointColor("#FF0000") == nil)
    }

    @Test func caseInsensitive() {
        #expect(parseCheckpointColor("RED") == .red)
        #expect(parseCheckpointColor("Red") == .red)
    }

    @Test func whitespaceTolerant() {
        #expect(parseCheckpointColor(" red ") == .red)
        #expect(parseCheckpointColor("\tblue\n") == .blue)
    }

    // MARK: - IsScoringTest (зеркало, 5)

    @Test func lockedWithUnknownCost_countsAsScoring() {
        #expect(cp(cost: nil, locked: true).isScoring == true)
    }

    @Test func lockedWithZeroCost_countsAsScoring() {
        #expect(cp(cost: 0, locked: true).isScoring == true)
    }

    @Test func openWithZeroCost_isTechnical_notScoring() {
        #expect(cp(cost: 0, locked: false).isScoring == false)
    }

    @Test func openWithNullCost_notScoring() {
        #expect(cp(cost: nil, locked: false).isScoring == false)
    }

    @Test func openWithPositiveCost_isScoring() {
        #expect(cp(cost: 5, locked: false).isScoring == true)
    }

    // MARK: - GroupCheckpointsByColorTest (зеркало, 6)

    @Test func contiguousSameColor_groupsIntoOneCard() {
        let groups = groupCheckpointsByColor([
            cp(id: 1, color: "red"), cp(id: 2, color: "red"), cp(id: 3, color: "red"),
        ])
        #expect(groups.count == 1)
        #expect(groups[0].map { $0.id } == [1, 2, 3])
    }

    @Test func colorChange_startsNewGroup() {
        let groups = groupCheckpointsByColor([
            cp(id: 1, color: "red"), cp(id: 2, color: "red"),
            cp(id: 3, color: "blue"), cp(id: 4, color: "green"), cp(id: 5, color: "green"),
        ])
        #expect(groups.map { g in g.map { $0.id } } == [[1, 2], [3], [4, 5]])
    }

    @Test func blankAndUnknownTokens_foldIntoOneNeutralGroup() {
        let groups = groupCheckpointsByColor([
            cp(id: 1, color: ""), cp(id: 2, color: "mauve"), cp(id: 3, color: ""),
        ])
        #expect(groups.count == 1)
        #expect(groups[0].map { $0.id } == [1, 2, 3])
    }

    @Test func recurringColor_inSeparateRuns_staysTwoCards() {
        let groups = groupCheckpointsByColor([
            cp(id: 1, color: "red"), cp(id: 2, color: "blue"), cp(id: 3, color: "red"),
        ])
        #expect(groups.map { g in g.map { $0.id } } == [[1], [2], [3]])
    }

    @Test func caseAndWhitespace_normalizeBeforeGrouping() {
        let groups = groupCheckpointsByColor([
            cp(id: 1, color: "red"), cp(id: 2, color: " RED "),
        ])
        #expect(groups.count == 1)
    }

    @Test func emptyInput_yieldsNoGroups() {
        #expect(groupCheckpointsByColor([]).isEmpty)
    }

    // MARK: - БОНУС-тесты (locked-скелетон)

    @Test func lockedSkeleton_isDeterministicFromId() {
        // firstBarFraction = 0.50 + floorMod(id*17,44)/100; hasSecondBar = floorMod(id*13,3)==0;
        // secondBarFraction = 0.28 + floorMod(id*29,26)/100.
        let a = lockedSkeletonBars(checkpointId: 3)
        let b = lockedSkeletonBars(checkpointId: 3)
        #expect(a == b)
        // id=3: 3*17=51, 51%44=7 → 0.57; 3*13=39, 39%3=0 → true; 3*29=87, 87%26=9 → 0.37.
        #expect(abs(a.firstBarFraction - 0.57) < 0.0001)
        #expect(a.hasSecondBar == true)
        #expect(abs(a.secondBarFraction - 0.37) < 0.0001)
    }

    @Test func lockedSkeleton_variesRowToRow() {
        // id=1: 17%44=17 → 0.67; 13%3=1 → false; 29%26=3 → 0.31.
        let one = lockedSkeletonBars(checkpointId: 1)
        #expect(abs(one.firstBarFraction - 0.67) < 0.0001)
        #expect(one.hasSecondBar == false)
        #expect(abs(one.secondBarFraction - 0.31) < 0.0001)
        #expect(one.firstBarFraction != lockedSkeletonBars(checkpointId: 3).firstBarFraction)
    }

    @Test func lockedSkeleton_fractionsStayInDesignRange() {
        for id in 1...200 {
            let bars = lockedSkeletonBars(checkpointId: id)
            #expect(bars.firstBarFraction >= 0.50 && bars.firstBarFraction < 0.94)
            #expect(bars.secondBarFraction >= 0.28 && bars.secondBarFraction < 0.54)
        }
    }
}
