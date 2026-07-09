//
//  MarksDisplayTests.swift
//  kolco24Tests
//
//  Зеркало не-фото кейсов `ui/marks/MarksMappingTest.kt` + `ui/marks/TileFillTest.kt`
//  (5). Имена сценариев сохранены.
//
//  Фото-кейсы `MarksMappingTest.kt` — **этап 7**, не портируются: `photoPaths and
//  photoCount map…`, `a tile without photos…`, `an nfc take can carry photo
//  evidence…`, `a corrupted photoPath column…`, все `lightboxPhotos*`, все
//  `photoReviewSummary*` (нет `photoPaths`/`lightboxPhotos`/`photoReviewSummary`
//  в iOS-порте до этапа 7). Лестница empty-состояний — бонус по урезанной логике
//  (NFC-ветки — этап 5).
//

import Foundation
import Testing
@testable import kolco24

struct MarksDisplayTests {

    private func mark(
        id: String,
        point: Int,
        number: Int,
        cost: Int,
        method: String = "nfc",
        complete: Bool = true,
        takenAt: Int64 = 1_000,
        trustedTakenAt: Int64? = nil
    ) -> Mark {
        Mark(
            id: id,
            raceId: 1,
            teamId: 7,
            checkpointId: point,
            checkpointNumber: number,
            cost: cost,
            method: method,
            cpUid: "UID",
            cpCode: "CODE",
            present: [],
            expectedCount: 0,
            complete: complete,
            takenAt: takenAt,
            updatedAt: takenAt,
            trustedTakenAt: trustedTakenAt
        )
    }

    private func hhmm(_ epochMs: Int64) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "HH:mm"
        return fmt.string(from: Date(timeIntervalSince1970: Double(epochMs) / 1000.0))
    }

    private func dt(_ epochMs: Int64) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "dd.MM.yyyy '·' HH:mm"
        return fmt.string(from: Date(timeIntervalSince1970: Double(epochMs) / 1000.0))
    }

    // MARK: - marksToTiles (зеркало не-фото)

    @Test func tilePerEvent_reversesToOldestFirst() {
        let marks = [
            mark(id: "a", point: 1, number: 1, cost: 2, takenAt: 3_000), // newest
            mark(id: "b", point: 2, number: 4, cost: 3, takenAt: 2_000),
            mark(id: "c", point: 3, number: 7, cost: 2, takenAt: 1_000), // oldest
        ]
        let tiles = marksToTiles(marks)
        #expect(tiles.count == 3)
        #expect(tiles.map { $0.number } == ["07", "04", "01"])
    }

    @Test func numberIsZeroPaddedToTwoDigits() {
        let tiles = marksToTiles([mark(id: "a", point: 1, number: 5, cost: 1)])
        #expect(tiles.first?.number == "05")
    }

    @Test func methodMapsToKind() {
        let tiles = marksToTiles([
            mark(id: "a", point: 1, number: 1, cost: 1, method: "nfc", takenAt: 2_000),
            mark(id: "b", point: 2, number: 2, cost: 1, method: "photo", takenAt: 1_000),
        ])
        // Oldest-first: photo (1_000) первым, nfc (2_000) последним.
        #expect(tiles[0].kind == .photo)
        #expect(tiles[1].kind == .nfc)
    }

    @Test func timeFormatsTakenAtAsHHmm() {
        let epoch: Int64 = 5_000_000
        let tiles = marksToTiles([mark(id: "a", point: 1, number: 1, cost: 1, takenAt: epoch)])
        #expect(tiles.first?.time == hhmm(epoch))
    }

    @Test func timePrefersTrustedTakenAt() {
        let wall: Int64 = 5_000_000
        let trusted = wall + 7 * 60_000 // 7 минут — HH:mm отличается
        let tiles = marksToTiles([
            mark(id: "a", point: 1, number: 1, cost: 1, takenAt: wall, trustedTakenAt: trusted),
        ])
        #expect(tiles.first?.time == hhmm(trusted))
        #expect(hhmm(trusted) != hhmm(wall))
    }

    @Test func timeFallsBackToTakenAtWhenTrustedNil() {
        let wall: Int64 = 5_000_000
        let tiles = marksToTiles([
            mark(id: "a", point: 1, number: 1, cost: 1, takenAt: wall, trustedTakenAt: nil),
        ])
        #expect(tiles.first?.time == hhmm(wall))
    }

    @Test func dateTimeFormatsEffectiveTakeTime() {
        let epoch: Int64 = 5_000_000
        let tiles = marksToTiles([mark(id: "a", point: 1, number: 1, cost: 1, takenAt: epoch)])
        #expect(tiles.first?.dateTime == dt(epoch))
    }

    @Test func dateTimePrefersTrustedTakenAtLikeTime() {
        let wall: Int64 = 5_000_000
        let trusted = wall + 7 * 60_000
        let tiles = marksToTiles([
            mark(id: "a", point: 1, number: 1, cost: 1, takenAt: wall, trustedTakenAt: trusted),
        ])
        #expect(tiles.first?.dateTime == dt(trusted))
    }

    @Test func emptyMarksYieldNoTiles() {
        #expect(marksToTiles([]).isEmpty)
    }

    @Test func incompleteTakesAreNotTiled() {
        let marks = [
            mark(id: "empty", point: 1, number: 1, cost: 2, complete: false, takenAt: 3_000),
            mark(id: "partial", point: 2, number: 4, cost: 3, complete: false, takenAt: 2_000),
        ]
        #expect(marksToTiles(marks).isEmpty)
    }

    @Test func onlyCompletedTakesAreTiledOldestFirst() {
        let marks = [
            mark(id: "incomplete", point: 1, number: 1, cost: 2, complete: false, takenAt: 4_000),
            mark(id: "done-new", point: 2, number: 4, cost: 3, complete: true, takenAt: 3_000),
            mark(id: "done-old", point: 3, number: 7, cost: 5, complete: true, takenAt: 2_000),
        ]
        #expect(marksToTiles(marks).map { $0.number } == ["07", "04"])
    }

    @Test func colorOfResolvesPerTakeCheckpointColor() {
        let tiles = marksToTiles(
            [
                mark(id: "a", point: 1, number: 1, cost: 1, takenAt: 2_000),
                mark(id: "b", point: 2, number: 2, cost: 1, takenAt: 1_000),
            ],
            colorOf: { $0.checkpointId == 1 ? .blue : nil }
        )
        // Oldest-first: point 2 (nil) первым, point 1 (BLUE) последним.
        #expect(tiles[0].color == nil)
        #expect(tiles[1].color == .blue)
    }

    @Test func colorDefaultsToNilWithoutResolver() {
        let tiles = marksToTiles([mark(id: "a", point: 1, number: 1, cost: 1)])
        #expect(tiles.first?.color == nil)
    }

    @Test func takenCountIsDistinctCompletePointsAndRepeatDoesNotDoubleScore() {
        let marks = [
            mark(id: "a", point: 1, number: 1, cost: 2, complete: true),
            mark(id: "b", point: 1, number: 1, cost: 2, complete: true), // повтор
            mark(id: "c", point: 2, number: 4, cost: 3, complete: true),
            mark(id: "d", point: 3, number: 7, cost: 5, complete: false), // partial
        ]
        #expect(takenPointCount(marks) == 2)
        #expect(totalScore(marks) == 5) // 2 + 3
    }

    @Test func takenPointCountLiveResolverExcludesTechnicalCheckpoints() {
        let marks = [
            mark(id: "a", point: 1, number: 1, cost: 0, complete: true), // технический
            mark(id: "b", point: 2, number: 4, cost: 3, complete: true),
        ]
        #expect(takenPointCount(marks) { $0.cost } == 1)
    }

    @Test func takenPointCountLiveResolverDoesNotDoubleCountRepeatedPoint() {
        let marks = [
            mark(id: "a", point: 1, number: 1, cost: 2, complete: true),
            mark(id: "b", point: 1, number: 1, cost: 2, complete: true), // повтор
            mark(id: "c", point: 2, number: 4, cost: 3, complete: true),
        ]
        #expect(takenPointCount(marks) { $0.cost } == 2)
    }

    @Test func takenPointCountLiveResolverIgnoresIncompleteTakes() {
        let marks = [
            mark(id: "a", point: 1, number: 1, cost: 2, complete: false),
            mark(id: "b", point: 2, number: 4, cost: 3, complete: true),
        ]
        #expect(takenPointCount(marks) { $0.cost } == 1)
    }

    @Test func totalScoreLiveResolverScoresOffCurrentCostNotSnapshot() {
        let marks = [
            mark(id: "a", point: 1, number: 1, cost: 0, complete: true), // stale snapshot
            mark(id: "b", point: 2, number: 4, cost: 3, complete: true),
        ]
        let liveCost = [1: 5, 2: 3]
        #expect(totalScore(marks) == 3)
        #expect(totalScore(marks) { liveCost[$0.checkpointId] ?? $0.cost } == 8)
    }

    @Test func totalScoreLiveResolverFallsBackToSnapshotForPointAbsentFromLegend() {
        let marks = [mark(id: "a", point: 9, number: 1, cost: 4, complete: true)]
        let empty: [Int: Int] = [:]
        #expect(totalScore(marks) { empty[$0.checkpointId] ?? $0.cost } == 4)
    }

    @Test func marksToTilesCostOfResolvesLiveTileCost() {
        let tiles = marksToTiles(
            [mark(id: "a", point: 1, number: 1, cost: 0, complete: true)],
            costOf: { [1: 5][$0.checkpointId] ?? $0.cost }
        )
        #expect(tiles.first?.cost == 5)
    }

    @Test func marksToTilesCostDefaultsToSnapshotWithoutResolver() {
        let tiles = marksToTiles([mark(id: "a", point: 1, number: 1, cost: 7)])
        #expect(tiles.first?.cost == 7)
    }

    @Test func photoMarkWithEmptyPresentAndCompleteIsTiled() {
        // Standalone фото-взятие (present=[] complete=true) всё равно тайлится
        // (фото-пути — этап 7, проверяется только факт тайла и kind).
        let tiles = marksToTiles([
            mark(id: "p", point: 1, number: 3, cost: 4, method: "photo", complete: true),
        ])
        #expect(tiles.count == 1)
        #expect(tiles.first?.kind == .photo)
    }

    // MARK: - hiddenTakenTokens / tokensLabel (зеркало)

    @Test func hiddenTakenTokens_masksDistinctCompleteLockedOldestFirst() {
        let marks = [
            mark(id: "a", point: 3, number: 7, cost: 0, method: "photo", takenAt: 4_000), // newest
            mark(id: "b", point: 2, number: 5, cost: 3, method: "nfc", takenAt: 3_000),   // open
            mark(id: "c", point: 3, number: 7, cost: 0, method: "photo", takenAt: 2_000), // repeat
            mark(id: "d", point: 1, number: 4, cost: 0, method: "photo", takenAt: 1_000), // oldest
        ]
        #expect(hiddenTakenTokens(marks, lockedIds: Set([1, 3])) == ["?-04", "?-07"])
    }

    // Порядок токенов — по возрастанию времени НОВЕЙШЕГО взятия каждого КП (Kotlin
    // distinctBy→asReversed), не по первому. КП1 взят @1000 и @4000, КП3 — @2000 и @3000:
    // по новейшему взятию КП3(3000) идёт раньше КП1(4000), а по первому было бы наоборот.
    @Test func hiddenTakenTokens_ordersByNewestTakeWhenInterleaved() {
        let marks = [
            mark(id: "a", point: 1, number: 4, cost: 0, method: "photo", takenAt: 4_000), // newest
            mark(id: "b", point: 3, number: 7, cost: 0, method: "photo", takenAt: 3_000),
            mark(id: "c", point: 3, number: 7, cost: 0, method: "photo", takenAt: 2_000),
            mark(id: "d", point: 1, number: 4, cost: 0, method: "photo", takenAt: 1_000), // oldest
        ]
        #expect(hiddenTakenTokens(marks, lockedIds: Set([1, 3])) == ["?-07", "?-04"])
    }

    @Test func hiddenTakenTokens_skipsIncompleteAndEmptyWhenNothingLockedTaken() {
        let marks = [
            mark(id: "a", point: 1, number: 4, cost: 0, method: "photo", complete: false),
            mark(id: "b", point: 2, number: 5, cost: 3, method: "nfc"),
        ]
        #expect(hiddenTakenTokens(marks, lockedIds: Set([1])).isEmpty)
        #expect(hiddenTakenTokens([], lockedIds: Set([1])).isEmpty)
        #expect(hiddenTakenTokens(marks, lockedIds: Set<Int>()).isEmpty)
    }

    @Test func tokensLabel_joinsUpToThreeAndCollapsesLongerTail() {
        #expect(tokensLabel(["1-02"]) == "1-02")
        #expect(tokensLabel(["1-02", "2-03", "5-04"]) == "1-02, 2-03, 5-04")
        #expect(tokensLabel(["1-02", "2-03", "5-04", "3-05", "4-06"]) == "1-02, 2-03, 5-04, …")
    }

    // MARK: - tileFill (зеркало TileFillTest, 5)

    @Test func eachColorMapsToItsMutedFill() {
        #expect(tileFill(.red, darkTheme: false).fill == 0xFFCB4233)
        #expect(tileFill(.orange, darkTheme: false).fill == 0xFFC15A2E)
        #expect(tileFill(.blue, darkTheme: false).fill == 0xFF2F6CAE)
        #expect(tileFill(.green, darkTheme: false).fill == 0xFF2E9E57)
        #expect(tileFill(.yellow, darkTheme: false).fill == 0xFFC99A1E)
        #expect(tileFill(.purple, darkTheme: false).fill == 0xFF7C5AC0)
    }

    @Test func whiteTextOnRedOrangeBlueGreenPurple() {
        for c in [CheckpointColor.red, .orange, .blue, .green, .purple] {
            #expect(tileFill(c, darkTheme: false).text == 0xFFFFFFFF)
        }
    }

    @Test func yellowUsesDarkInkText() {
        #expect(tileFill(.yellow, darkTheme: false).text == 0xFF161A1F)
    }

    @Test func neutralFillDiffersLightVsDark() {
        let light = tileFill(nil, darkTheme: false)
        let dark = tileFill(nil, darkTheme: true)
        #expect(light.fill == 0xFFD6DCE4)
        #expect(light.text == 0xFF161A1F)
        #expect(dark.fill == 0xFF2A323C)
        #expect(dark.text == 0xFFD6DCE4)
        #expect(light.fill != dark.fill)
        #expect(light.text != dark.text)
    }

    @Test func nonNeutralFillsIdenticalInLightAndDark() {
        for c in [CheckpointColor.red, .blue, .green, .yellow, .orange, .purple] {
            #expect(tileFill(c, darkTheme: false).fill == tileFill(c, darkTheme: true).fill)
            #expect(tileFill(c, darkTheme: false).text == tileFill(c, darkTheme: true).text)
        }
    }

    // MARK: - БОНУС-тесты (лестница empty-состояний, урезанная — NFC-ветки этапа 5)

    @Test func marksEmptyState_loadingSuppressesEverything() {
        #expect(marksEmptyState(loading: true, hasTeam: false, memberCount: 0, boundCount: 0) == .none)
        #expect(marksEmptyState(loading: true, hasTeam: true, memberCount: 3, boundCount: 0) == .none)
    }

    @Test func marksEmptyState_noTeamChoosesTeam() {
        #expect(marksEmptyState(loading: false, hasTeam: false, memberCount: 0, boundCount: 0) == .chooseTeam)
    }

    @Test func marksEmptyState_unboundMembersNudgeBinding() {
        #expect(marksEmptyState(loading: false, hasTeam: true, memberCount: 3, boundCount: 1) == .bindChips)
        #expect(marksEmptyState(loading: false, hasTeam: true, memberCount: 3, boundCount: 0) == .bindChips)
    }

    @Test func marksEmptyState_allBoundOrNoRosterIsReady() {
        #expect(marksEmptyState(loading: false, hasTeam: true, memberCount: 3, boundCount: 3) == .ready)
        #expect(marksEmptyState(loading: false, hasTeam: true, memberCount: 0, boundCount: 0) == .ready)
    }
}
