//
//  MarksDisplayPhotoTests.swift
//  kolco24Tests
//
//  Зеркало фото-кейсов `ui/marks/MarksMappingTest.kt` (этап 7): `photoPaths`/
//  `photoCount` на тайле, `lightboxPhotos*`, `photoReviewSummary*`. Имена
//  сценариев сохранены. Не-фото кейсы — в `MarksDisplayTests.swift`.
//

import Testing
@testable import kolco24

struct MarksDisplayPhotoTests {

    private func mark(
        id: String,
        point: Int,
        number: Int,
        cost: Int,
        method: String = "photo",
        complete: Bool = true,
        takenAt: Int64 = 1_000,
        photoPath: String? = nil
    ) -> Mark {
        Mark(
            id: id,
            raceId: 1,
            teamId: 7,
            checkpointId: point,
            checkpointNumber: number,
            cost: cost,
            method: method,
            cpUid: method == "photo" ? "" : "UID",
            cpCode: method == "photo" ? "" : "CODE",
            present: [],
            expectedCount: 0,
            complete: complete,
            photoPath: photoPath,
            takenAt: takenAt,
            updatedAt: takenAt
        )
    }

    private func tile(
        number: String,
        cost: Int,
        kind: MarkTileKind,
        time: String,
        photoPaths: [String] = []
    ) -> MarkTile {
        MarkTile(number: number, cost: cost, kind: kind, time: time, photoPaths: photoPaths)
    }

    // MARK: - marksToTiles (фото-поля)

    @Test func photoPathsAndPhotoCountMapFromTheEncodedPhotoPathColumn() {
        let paths = ["marks/a/1.jpg", "marks/a/2.jpg", "marks/a/3.jpg"]
        let tiles = marksToTiles(
            [mark(id: "a", point: 1, number: 1, cost: 1, photoPath: PhotoPaths.encode(paths))]
        )
        // Порядок сохранён, бейдж — производный размер списка.
        #expect(tiles.count == 1)
        #expect(tiles[0].photoPaths == paths)
        #expect(tiles[0].photoCount == 3)
    }

    @Test func aTileWithoutPhotosHasEmptyPathsAndZeroCount() {
        let tiles = marksToTiles([mark(id: "a", point: 1, number: 1, cost: 1, method: "nfc")])
        #expect(tiles[0].photoPaths.isEmpty)
        #expect(tiles[0].photoCount == 0)
    }

    @Test func anNfcTakeCanCarryPhotoEvidenceSoTheBadgeShowsOnAColoredTile() {
        // NFC-тайл сохраняет kind, но photoCount > 0 гонит бейдж «+N» независимо.
        let tiles = marksToTiles([
            mark(
                id: "a", point: 1, number: 1, cost: 2, method: "nfc",
                photoPath: PhotoPaths.encode(["marks/a/1.jpg"])
            ),
        ])
        #expect(tiles[0].kind == .nfc)
        #expect(tiles[0].photoCount == 1)
    }

    @Test func aPhotoMarkWithEmptyPresentAndCompleteIsTiled() {
        // Standalone фото-взятие (ростер не сканирован) — present=[] complete=true; тайлится.
        let tiles = marksToTiles([
            mark(
                id: "p", point: 1, number: 3, cost: 4,
                photoPath: PhotoPaths.encode(["marks/p/1.jpg"])
            ),
        ])
        #expect(tiles.count == 1)
        #expect(tiles[0].kind == .photo)
        #expect(tiles[0].photoCount == 1)
    }

    @Test func aCorruptedPhotoPathColumnDegradesToNoPhotos() {
        // PhotoPaths.decode никогда не бросает — мусор декодируется в [], тайл просто без бейджа.
        let tiles = marksToTiles([mark(id: "a", point: 1, number: 1, cost: 1, photoPath: "{not json")])
        #expect(tiles[0].photoPaths.isEmpty)
        #expect(tiles[0].photoCount == 0)
    }

    // MARK: - lightboxPhotos

    @Test func lightboxPhotosFlattensEveryTakesFramesInGridOrderCarryingTheOwningMark() {
        // Тайлы приходят oldest-first (как отдаёт marksToTiles); лента сохраняет
        // порядок и конкатенирует список кадров каждого взятия.
        let a = tile(
            number: "01", cost: 2, kind: .photo, time: "10:00",
            photoPaths: ["marks/a/1.jpg", "marks/a/2.jpg"]
        )
        let b = tile(
            number: "04", cost: 3, kind: .nfc, time: "10:05",
            photoPaths: ["marks/b/1.jpg"]
        )
        let strip = lightboxPhotos([a, b])
        #expect(strip.map { $0.path } == ["marks/a/1.jpg", "marks/a/2.jpg", "marks/b/1.jpg"])
        // Каждый кадр несёт своё взятие — КП-чип страницы резолвится корректно.
        #expect(strip.map { $0.tile } == [a, a, b])
    }

    @Test func lightboxPhotosSkipsTakesWithoutPhotos() {
        let withPhoto = tile(
            number: "01", cost: 2, kind: .photo, time: "10:00", photoPaths: ["marks/a/1.jpg"]
        )
        let noPhoto = tile(number: "04", cost: 3, kind: .nfc, time: "10:05")
        let strip = lightboxPhotos([noPhoto, withPhoto, noPhoto])
        #expect(strip.map { $0.path } == ["marks/a/1.jpg"])
    }

    @Test func lightboxPhotosOfNoTilesIsEmpty() {
        #expect(lightboxPhotos([]).isEmpty)
    }

    // MARK: - photoReviewSummary

    @Test func photoReviewSummaryIsNilWhenThereAreNoPhotoTakes() {
        #expect(photoReviewSummary([]) == nil)
        #expect(photoReviewSummary([mark(id: "a", point: 1, number: 1, cost: 2, method: "nfc")]) == nil)
    }

    @Test func photoReviewSummaryCountsCompletePhotoTakesAndSumsTheirPoints() {
        let marks = [
            mark(id: "a", point: 1, number: 1, cost: 2),
            mark(id: "b", point: 2, number: 2, cost: 3),
            mark(id: "c", point: 3, number: 3, cost: 5, method: "nfc"),
        ]
        #expect(
            photoReviewSummary(marks)
                == PhotoReviewSummary(count: 2, points: 5, tokens: ["3-02", "2-01"])
        )
    }

    @Test func photoReviewSummaryCountsARepeatPhotoTakeOfTheSameKpOnce() {
        // По-КП, зеркаля distinctBy(checkpointId) метрик: два фото-взятия одного КП —
        // один КП на проверке, его баллы считаются однажды.
        let marks = [
            mark(id: "a", point: 1, number: 1, cost: 2, takenAt: 2_000),
            mark(id: "b", point: 1, number: 1, cost: 2, takenAt: 1_000),
        ]
        #expect(
            photoReviewSummary(marks)
                == PhotoReviewSummary(count: 1, points: 2, tokens: ["2-01"])
        )
    }

    @Test func photoReviewSummaryExcludesAKpThatAlsoHasACompleteNfcTake() {
        // Чип уже доказывает посещение (баллы идут от NFC-взятия) — отдельному
        // фото-взятию того же КП проверка судьи не нужна.
        let marks = [
            mark(id: "a", point: 1, number: 1, cost: 2, takenAt: 2_000),
            mark(id: "b", point: 1, number: 1, cost: 2, method: "nfc", takenAt: 1_000),
            mark(id: "c", point: 2, number: 2, cost: 3, takenAt: 3_000),
        ]
        #expect(
            photoReviewSummary(marks)
                == PhotoReviewSummary(count: 1, points: 3, tokens: ["3-02"])
        )
    }

    @Test func photoReviewSummaryIgnoresAnIncompleteNfcTakeWhenExcludingChipVerifiedKp() {
        // Незавершённое NFC-взятие в зачёт не пошло — фото-взятие всё ещё
        // единственное доказательство КП.
        let marks = [
            mark(id: "a", point: 1, number: 1, cost: 2, takenAt: 2_000),
            mark(id: "b", point: 1, number: 1, cost: 2, method: "nfc", complete: false, takenAt: 1_000),
        ]
        #expect(
            photoReviewSummary(marks)
                == PhotoReviewSummary(count: 1, points: 2, tokens: ["2-01"])
        )
    }

    @Test func photoReviewSummarySkipsIncompletePhotoTakes() {
        let marks = [
            mark(id: "a", point: 1, number: 1, cost: 2),
            mark(id: "b", point: 2, number: 2, cost: 3, complete: false),
        ]
        #expect(
            photoReviewSummary(marks)
                == PhotoReviewSummary(count: 1, points: 2, tokens: ["2-01"])
        )
    }

    @Test func photoReviewSummaryIgnoresAnNfcTakeThatMerelyAttachedPhotoEvidence() {
        // Чип читался — судьям проверять нечего, в нотис не попадает.
        let marks = [
            mark(
                id: "a", point: 1, number: 1, cost: 2, method: "nfc",
                photoPath: PhotoPaths.encode(["marks/a/1.jpg"])
            ),
        ]
        #expect(photoReviewSummary(marks) == nil)
    }

    @Test func photoReviewSummaryScoresThroughTheLiveCostOfNotTheSnapshot() {
        // Фото-взятие ещё-залоченного КП снимает cost=0; на reveal побеждает
        // живая цена легенды.
        let marks = [mark(id: "a", point: 7, number: 1, cost: 0)]
        let live = [7: 30]
        let summary = photoReviewSummary(marks) { live[$0.checkpointId] ?? $0.cost }
        #expect(summary == PhotoReviewSummary(count: 1, points: 30, tokens: ["30-01"]))
    }

    @Test func photoReviewSummaryTokensFollowGridOrderAndDropTheCostPrefixOnAZeroCostKp() {
        // Вход newest-first (как отдаёт observation); токены возвращаются
        // oldest-first, как тайловая сетка. КП с нулевой ценой (ещё-залоченный
        // в легенде) — голый zero-padded номер, зеркаля токен тайла.
        let marks = [
            mark(id: "a", point: 3, number: 4, cost: 5, takenAt: 3_000), // newest
            mark(id: "b", point: 2, number: 3, cost: 0, takenAt: 2_000),
            mark(id: "c", point: 1, number: 2, cost: 1, takenAt: 1_000), // oldest
        ]
        #expect(photoReviewSummary(marks)?.tokens == ["1-02", "03", "5-04"])
    }
}
