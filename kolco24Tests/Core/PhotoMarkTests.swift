//
//  PhotoMarkTests.swift
//  kolco24Tests
//
//  Тесты чистой фабрики `makePhotoMark` — зеркало семантики
//  `MarkRepository.createPhotoMark` (L211–243; на Android конструирование не
//  выделено в чистую функцию, отдельного JVM-теста нет — кейсы свежие по
//  конвенции этапа). DAO-часть (`attachPhotos`, photo-upload-флаги) уже
//  зеркалирована `MarkStore`-тестами.
//

import Testing
@testable import kolco24

struct PhotoMarkTests {

    private func sample(
        wall: Int64 = 1_000,
        elapsed: Int64 = 5_000,
        trusted: Int64? = 2_000,
        boot: Int? = 42
    ) -> TimeSample {
        TimeSample(wallMs: wall, elapsedMs: elapsed, trustedMs: trusted, bootCount: boot)
    }

    private func cp(id: Int = 9, number: Int = 32, cost: Int? = 5, locked: Bool = false) -> Checkpoint {
        Checkpoint(
            id: id,
            raceId: 1,
            number: number,
            cost: cost,
            type: "regular",
            description: cost == nil ? nil : "у ручья",
            locked: locked
        )
    }

    private func make(
        cp checkpoint: Checkpoint? = nil,
        paths: [String] = ["marks/m1/a.jpg"],
        expectedCount: Int = 4,
        sample s: TimeSample? = nil
    ) -> Mark {
        makePhotoMark(
            markId: "m1",
            cp: checkpoint ?? cp(),
            raceId: 1,
            teamId: 7,
            paths: paths,
            expectedCount: expectedCount,
            sample: s ?? sample()
        )
    }

    @Test func createPhotoMark_hybridTakeFields() {
        // method="photo", complete=true, present=[] (состав не утверждается),
        // presentDetails=nil, cpUid/cpCode пустые (чип не читался).
        let mark = make()
        #expect(mark.id == "m1")
        #expect(mark.raceId == 1)
        #expect(mark.teamId == 7)
        #expect(mark.checkpointId == 9)
        #expect(mark.checkpointNumber == 32)
        #expect(mark.cost == 5)
        #expect(mark.method == "photo")
        #expect(mark.cpUid == "")
        #expect(mark.cpCode == "")
        #expect(mark.present.isEmpty)
        #expect(mark.presentDetails == nil)
        #expect(mark.complete == true)
    }

    @Test func createPhotoMark_encodesRelativePathsIntoPhotoPath() {
        let paths = ["marks/m1/a.jpg", "marks/m1/b.jpg"]
        let mark = make(paths: paths)
        // Round-trip через Core-кодек: порядок кадров сохранён.
        #expect(PhotoPaths.decode(mark.photoPath) == paths)
    }

    @Test func createPhotoMark_lockedCheckpointCostFallsBackToZero() {
        // Залоченный КП несёт cost=nil — снимок 0; живой резолвер цены легенды
        // подставит реальную после раскрытия.
        let mark = make(cp: cp(cost: nil, locked: true))
        #expect(mark.cost == 0)
        #expect(mark.complete == true)
    }

    @Test func createPhotoMark_expectedCountStoredButDoesNotDriveComplete() {
        // expectedCount — только для серверного лога; complete=true ставится явно,
        // даже при ростере больше нуля присутствующих (present пуст).
        let mark = make(expectedCount: 4)
        #expect(mark.expectedCount == 4)
        #expect(mark.present.isEmpty)
        #expect(mark.complete == true)
    }

    @Test func createPhotoMark_writesAllTimesFromSample() {
        let mark = make(sample: sample(wall: 1_000, elapsed: 5_000, trusted: 2_000, boot: 42))
        // wall гонит и takenAt, и updatedAt; trusted/elapsed/boot — verbatim.
        #expect(mark.takenAt == 1_000)
        #expect(mark.updatedAt == 1_000)
        #expect(mark.trustedTakenAt == 2_000)
        #expect(mark.elapsedRealtimeAt == 5_000)
        #expect(mark.bootCount == 42)
    }

    @Test func createPhotoMark_nullTrustedAndBoot_persistAsNull() {
        // NoSync (нет якоря часов): trustedMs/bootCount = nil, колонки остаются nil.
        let mark = make(sample: sample(trusted: nil, boot: nil))
        #expect(mark.trustedTakenAt == nil)
        #expect(mark.bootCount == nil)
    }

    @Test func createPhotoMark_freshRowHasNoUploadFlagsOrLocation() {
        // Свежая строка: не выгружена никуда, без координаты (attachLocation —
        // отдельная фаза, fire-and-forget).
        let mark = make()
        #expect(mark.uploadedLocal == false)
        #expect(mark.uploadedCloud == false)
        #expect(mark.photosUploadedLocal == false)
        #expect(mark.photosUploadedCloud == false)
        #expect(mark.locLat == nil)
    }

    @Test func createPhotoMark_isTiledAndScores() {
        // Standalone фото-взятие (present=[], complete=true) тайлится и идёт в зачёт.
        let mark = make()
        #expect(takenPoints([mark]) == Set([9]))
        let tiles = marksToTiles([mark])
        #expect(tiles.count == 1)
        #expect(tiles[0].kind == .photo)
    }
}
