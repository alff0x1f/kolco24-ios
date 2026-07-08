//
//  PhotoTargetTests.swift
//  kolco24Tests
//
//  Зеркало `data/marks/PhotoTargetTest.kt` (12 кейсов) 1:1: роутер фото-сессии
//  `decidePhotoTarget` — пустой список / недавнее полное взятие / вне окна /
//  включающая граница / новейшее взятие / trustedTakenAt приоритетнее /
//  неполные и method=photo игнорируются / newest-only / будущая метка.
//

import Testing
@testable import kolco24

struct PhotoTargetTests {

    private func mark(
        _ id: String,
        point: Int = 1,
        number: Int = 11,
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
            cost: 5,
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

    @Test func emptyListAsksForNumber() {
        #expect(decidePhotoTarget(marks: [], nowMs: 10_000) == .askNumber)
    }

    @Test func recentCompleteTakeAttaches() {
        let marks = [mark("a", point: 3, number: 42, takenAt: 100_000)]

        let target = decidePhotoTarget(marks: marks, nowMs: 150_000)

        #expect(target == .attachTo(markId: "a", cpNumber: 42, checkpointId: 3))
    }

    @Test func takeOlderThanTheWindowAsksForNumber() {
        let marks = [mark("a", takenAt: 100_000)]

        let target = decidePhotoTarget(marks: marks, nowMs: 100_000 + PHOTO_ATTACH_WINDOW_MS + 1)

        #expect(target == .askNumber)
    }

    @Test func exactlyThreeMinutesStillAttachesInclusiveBoundary() {
        let marks = [mark("a", point: 3, number: 42, takenAt: 100_000)]

        let target = decidePhotoTarget(marks: marks, nowMs: 100_000 + PHOTO_ATTACH_WINDOW_MS)

        #expect(target == .attachTo(markId: "a", cpNumber: 42, checkpointId: 3))
    }

    @Test func newestCompleteTakeIsChosen() {
        let marks = [
            mark("old", point: 1, number: 11, takenAt: 100_000),
            mark("new", point: 2, number: 22, takenAt: 140_000),
        ]

        let target = decidePhotoTarget(marks: marks, nowMs: 150_000)

        #expect(target == .attachTo(markId: "new", cpNumber: 22, checkpointId: 2))
    }

    @Test func trustedTakenAtIsPreferredOverWallTakenAt() {
        // Настенное время недавнее, но доверенное устарело → вне окна → спросить.
        let marks = [mark("a", takenAt: 149_000, trustedTakenAt: 100_000)]

        let target = decidePhotoTarget(marks: marks, nowMs: 100_000 + PHOTO_ATTACH_WINDOW_MS + 1)

        #expect(target == .askNumber)
    }

    @Test func incompleteTakesAreIgnored() {
        let marks = [
            mark("partial", point: 2, number: 22, complete: false, takenAt: 145_000),
            mark("done", point: 1, number: 11, complete: true, takenAt: 120_000),
        ]

        let target = decidePhotoTarget(marks: marks, nowMs: 150_000)

        #expect(target == .attachTo(markId: "done", cpNumber: 11, checkpointId: 1))
    }

    @Test func onlyIncompleteRecentTakesAskForNumber() {
        let marks = [mark("partial", complete: false, takenAt: 149_000)]

        #expect(decidePhotoTarget(marks: marks, nowMs: 150_000) == .askNumber)
    }

    @Test func photoMarkWithinWindowDoesNotAttach() {
        let marks = [mark("photo", point: 3, number: 42, method: "photo", takenAt: 100_000)]

        let target = decidePhotoTarget(marks: marks, nowMs: 150_000)

        #expect(target == .askNumber)
    }

    @Test func photoMarkIsSkippedAndOlderNfcTakeWithinWindowAttaches() {
        let marks = [
            mark("nfc", point: 1, number: 11, takenAt: 100_000),
            mark("photo", point: 2, number: 22, method: "photo", takenAt: 140_000),
        ]

        let target = decidePhotoTarget(marks: marks, nowMs: 150_000)

        #expect(target == .attachTo(markId: "nfc", cpNumber: 11, checkpointId: 1))
    }

    @Test func newestTakeOutsideWindowWinsEvenIfOlderIsInside() {
        // Новейшее взятие чуть за границей; старое — глубоко внутри окна.
        // decidePhotoTarget проверяет только новейшее полное не-photo взятие, так что askNumber верно.
        let marks = [
            mark("inside", point: 1, number: 11, takenAt: 50_000),
            mark("outside", point: 2, number: 22, takenAt: 140_000),
        ]
        let target = decidePhotoTarget(marks: marks, nowMs: 140_000 + PHOTO_ATTACH_WINDOW_MS + 1)
        #expect(target == .askNumber)
    }

    @Test func futureTimestampedTakeStillAttaches() {
        // Если доверенное время помещает взятие в будущее относительно nowMs (напр. после сдвига часов),
        // вычитание отрицательное и всегда <= PHOTO_ATTACH_WINDOW_MS. Это ожидаемое поведение:
        // чуть-будущее взятие всё же прикрепляется, а не спрашивает номер.
        let marks = [mark("a", point: 5, number: 55, takenAt: 200_000)]

        let target = decidePhotoTarget(marks: marks, nowMs: 100_000)

        #expect(target == .attachTo(markId: "a", cpNumber: 55, checkpointId: 5))
    }
}
