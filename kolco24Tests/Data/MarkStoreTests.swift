//
//  MarkStoreTests.swift
//  kolco24Tests
//
//  Зеркало `MarkDaoTest.kt` (12 кейсов) поверх in-memory GRDB — фото-контракты
//  `MarkStore`: дренаж metadata/frames, CASE-агрегаты `uploadCounts`, транзакция
//  `attachPhotos`. Плюс БОНУС-тесты (на Android покрыты только репо-тестами на
//  фейках, не реальным SQL): `addMember` (set-семантика present/presentDetails,
//  пересчёт `complete`, сброс `uploaded*`), `attachLocation`, version-guarded
//  `markUploaded*IfUnchanged`/`…AndNoLocation`.
//

import GRDB
import Testing
@testable import kolco24

struct MarkStoreTests {

    private func makeStore() throws -> MarkStore {
        MarkStore(try AppDatabase.makeInMemory().writer)
    }

    /// Первое значение observation'а (эмитится сразу на подписке).
    private func firstValue<T>(_ observation: AsyncValueObservation<T>) async throws -> T {
        for try await value in observation {
            return value
        }
        throw CancellationError()
    }

    /// Зеркало `MarkDaoTest.mark(...)`: photo-строка нулит cost/cpUid/cpCode/present
    /// и ждёт 3 кадра; остальные — nfc-строка с одним участником.
    private func mark(
        _ id: String,
        method: String,
        raceId: Int = 1,
        teamId: Int = 7,
        photoPath: String? = nil,
        uploadedLocal: Bool = false,
        uploadedCloud: Bool = false,
        photosUploadedLocal: Bool = false,
        photosUploadedCloud: Bool = false,
        updatedAt: Int64 = 1_000
    ) -> Mark {
        let isPhoto = method == "photo"
        return Mark(
            id: id,
            raceId: raceId,
            teamId: teamId,
            checkpointId: 10,
            checkpointNumber: 10,
            cost: isPhoto ? 0 : 5,
            method: method,
            cpUid: isPhoto ? "" : "CPUID",
            cpCode: isPhoto ? "" : "CODE",
            present: isPhoto ? [] : [1],
            expectedCount: isPhoto ? 3 : 1,
            complete: true,
            photoPath: photoPath,
            takenAt: 1_000,
            updatedAt: updatedAt,
            uploadedLocal: uploadedLocal,
            uploadedCloud: uploadedCloud,
            photosUploadedLocal: photosUploadedLocal,
            photosUploadedCloud: photosUploadedCloud
        )
    }

    // MARK: - Зеркала MarkDaoTest.kt (12 кейсов)

    @Test func unuploadedLocalAndCloud_includePhotoMarks() async throws {
        // Phase 2: photo-mark metadata теперь делит дренаж с nfc-отметками (фильтр снят).
        let store = try makeStore()
        try await store.upsert(mark("nfc-1", method: "nfc"))
        try await store.upsert(mark("photo-1", method: "photo"))

        let local = Set(try await store.unuploadedLocal(raceId: 1, teamId: 7, limit: 100).map(\.id))
        let cloud = Set(try await store.unuploadedCloud(raceId: 1, teamId: 7, limit: 100).map(\.id))

        #expect(local == ["nfc-1", "photo-1"])
        #expect(cloud == ["nfc-1", "photo-1"])
    }

    @Test func uploadCounts_photoMarkCountsOnlyWhenMetadataAndFramesUploaded() async throws {
        let store = try makeStore()
        try await store.upsert(mark("nfc-1", method: "nfc", uploadedLocal: true, uploadedCloud: true))
        // Metadata загружена, кадры ещё нет — не должна считаться uploaded ни для одного таргета.
        try await store.upsert(mark(
            "photo-1", method: "photo", photoPath: "[\"marks/photo-1/a.jpg\"]",
            uploadedLocal: true, uploadedCloud: true,
            photosUploadedLocal: false, photosUploadedCloud: false
        ))

        let counts = try await firstValue(store.uploadCounts(teamId: 7, raceId: 1))
        #expect(counts.total == 2)
        #expect(counts.local == 1)
        #expect(counts.cloud == 1)

        try await store.setPhotosUploadedLocalIfUnchanged(id: "photo-1", updatedAt: 1_000)
        try await store.setPhotosUploadedCloudIfUnchanged(id: "photo-1", updatedAt: 1_000)

        let countsAfter = try await firstValue(store.uploadCounts(teamId: 7, raceId: 1))
        #expect(countsAfter.local == 2)
        #expect(countsAfter.cloud == 2)
    }

    @Test func uploadCountsMetadata_ignoresPendingFrames() async throws {
        let store = try makeStore()
        try await store.upsert(mark("nfc-1", method: "nfc", uploadedLocal: true, uploadedCloud: true))
        // Metadata загружена, кадры ещё нет — но для metadata-only-вида строка всё равно считается.
        try await store.upsert(mark(
            "photo-1", method: "photo", photoPath: "[\"marks/photo-1/a.jpg\"]",
            uploadedLocal: true, uploadedCloud: false,
            photosUploadedLocal: false, photosUploadedCloud: false
        ))

        let counts = try await firstValue(store.uploadCountsMetadata(teamId: 7, raceId: 1))

        #expect(counts.total == 2)
        #expect(counts.local == 2)
        #expect(counts.cloud == 1)
    }

    @Test func photoFrameRows_returnsOnlyPhotoRowsWithFlags() async throws {
        let store = try makeStore()
        try await store.upsert(mark("nfc-1", method: "nfc", uploadedLocal: true, uploadedCloud: true))
        try await store.upsert(mark(
            "photo-1", method: "photo", photoPath: "[\"marks/photo-1/a.jpg\"]",
            photosUploadedLocal: true, photosUploadedCloud: false
        ))

        let rows = try await firstValue(store.photoFrameRows(teamId: 7, raceId: 1))

        #expect(rows == [PhotoFrameRow(
            photoPath: "[\"marks/photo-1/a.jpg\"]",
            photosUploadedLocal: true,
            photosUploadedCloud: false
        )])
    }

    @Test func pendingUploadScopes_includesPhotoOnlyScope() async throws {
        // Phase 2: скоуп только с фото-отметкой больше не исключается (фильтр снят).
        let store = try makeStore()
        try await store.upsert(mark("nfc-1", method: "nfc", raceId: 1, teamId: 7))
        try await store.upsert(mark("photo-1", method: "photo", raceId: 9, teamId: 3))

        let scopes = try await store.pendingUploadScopes()

        #expect(scopes.contains(TrackScope(raceId: 1, teamId: 7)))
        #expect(scopes.contains(TrackScope(raceId: 9, teamId: 3)))
    }

    @Test func pendingUploadScopes_widenedForPendingFramesOnly() async throws {
        // Metadata полностью загружена, но кадры ещё pending — скоуп всё равно возвращается,
        // чтобы frame-дренаж продолжал пере-триггериться.
        let store = try makeStore()
        try await store.upsert(mark(
            "photo-1", method: "photo", raceId: 5, teamId: 2,
            photoPath: "[\"marks/photo-1/a.jpg\"]",
            uploadedLocal: true, uploadedCloud: true,
            photosUploadedLocal: true, photosUploadedCloud: false
        ))

        let scopes = try await store.pendingUploadScopes()

        #expect(scopes.contains(TrackScope(raceId: 5, teamId: 2)))
    }

    @Test func framePending_filtersByMetadataUploadedFlagAndFlagAndPath() async throws {
        let store = try makeStore()
        // Годна: metadata загружена, кадры нет, есть photoPath.
        try await store.upsert(mark(
            "eligible", method: "photo", photoPath: "[\"marks/eligible/a.jpg\"]",
            uploadedLocal: true, photosUploadedLocal: false
        ))
        // Исключена: metadata ещё не загружена (uploadedLocal = 0).
        try await store.upsert(mark(
            "no-metadata", method: "photo", photoPath: "[\"marks/no-metadata/a.jpg\"]",
            uploadedLocal: false, photosUploadedLocal: false
        ))
        // Исключена: кадры уже загружены (photosUploadedLocal = 1).
        try await store.upsert(mark(
            "frames-done", method: "photo", photoPath: "[\"marks/frames-done/a.jpg\"]",
            uploadedLocal: true, photosUploadedLocal: true
        ))
        // Исключена: нет photoPath.
        try await store.upsert(mark("no-photo", method: "nfc", uploadedLocal: true, photosUploadedLocal: false))

        let pending = try await store.framePendingLocal(raceId: 1, teamId: 7, limit: 100).map(\.id)

        #expect(pending == ["eligible"])
    }

    @Test func framePending_zeroFrameRowIsStillSelected() async throws {
        // Пустой-но-не-NULL photoPath ("[]") — кандидат frame-дренажа на уровне DAO;
        // цикл дренажа репозитория сам мгновенно флипнет его без спина.
        let store = try makeStore()
        try await store.upsert(mark(
            "zero-frames", method: "photo", photoPath: "[]",
            uploadedLocal: true, photosUploadedLocal: false
        ))

        let pending = try await store.framePendingLocal(raceId: 1, teamId: 7, limit: 100).map(\.id)

        #expect(pending == ["zero-frames"])
    }

    @Test func setPhotosUploadedIfUnchanged_flipsOnMatchingUpdatedAt_noOpsOnStale() async throws {
        let store = try makeStore()
        try await store.upsert(mark(
            "photo-1", method: "photo", photoPath: "[\"marks/photo-1/a.jpg\"]",
            uploadedLocal: true, uploadedCloud: true, updatedAt: 1_000
        ))

        // Устаревший updatedAt (имитация гонки с attachPhotos) — должен no-op.
        try await store.setPhotosUploadedLocalIfUnchanged(id: "photo-1", updatedAt: 999)
        #expect(try await store.getById("photo-1")?.photosUploadedLocal == false)

        // Совпадающий updatedAt — флипает.
        try await store.setPhotosUploadedLocalIfUnchanged(id: "photo-1", updatedAt: 1_000)
        try await store.setPhotosUploadedCloudIfUnchanged(id: "photo-1", updatedAt: 1_000)
        let row = try #require(try await store.getById("photo-1"))
        #expect(row.photosUploadedLocal == true)
        #expect(row.photosUploadedCloud == true)
    }

    @Test func attachPhotos_mergesPaths_onlyTouchesPhotoPathAndUpdatedAt() async throws {
        // Уже загруженная nfc-строка: attach фото должен слить пути и bump updatedAt, но оставить
        // uploaded* и present нетронутыми (photoPath не в marks-DTO).
        let store = try makeStore()
        try await store.upsert(mark("nfc-1", method: "nfc", uploadedLocal: true, uploadedCloud: true))

        try await store.attachPhotos(id: "nfc-1", newPaths: ["marks/nfc-1/a.jpg"], now: 2_000)
        try await store.attachPhotos(id: "nfc-1", newPaths: ["marks/nfc-1/b.jpg"], now: 3_000)

        let row = try #require(try await store.getById("nfc-1"))
        #expect(MarkPhotoPaths.decode(row.photoPath) == ["marks/nfc-1/a.jpg", "marks/nfc-1/b.jpg"])
        #expect(row.updatedAt == 3_000)
        // uploaded* не изменены — photoPath не в upload-DTO.
        #expect(row.uploadedLocal == true)
        #expect(row.uploadedCloud == true)
        // Остальные колонки не тронуты column-scoped UPDATE'ом.
        #expect(row.present == [1])
        #expect(row.complete == true)
        #expect(row.cpUid == "CPUID")
        #expect(row.cpCode == "CODE")
        #expect(row.takenAt == 1_000)
    }

    @Test func attachPhotos_missingRow_isNoOp() async throws {
        let store = try makeStore()
        try await store.attachPhotos(id: "nope", newPaths: ["marks/nope/a.jpg"], now: 2_000)
        #expect(try await store.getById("nope") == nil)
    }

    @Test func attachPhotos_onFullyFrameUploadedRow_resetsPhotosUploadedButLeavesUploadedIntact() async throws {
        // Строка, чьи кадры уже полностью дренированы: добавление нового кадра пере-очередит
        // frame-дренаж (photosUploaded* -> 0), не трогая metadata-флаги uploaded*.
        let store = try makeStore()
        try await store.upsert(mark(
            "photo-1", method: "photo",
            photoPath: "[\"marks/photo-1/a.jpg\"]",
            uploadedLocal: true, uploadedCloud: true,
            photosUploadedLocal: true, photosUploadedCloud: true
        ))

        try await store.attachPhotos(id: "photo-1", newPaths: ["marks/photo-1/b.jpg"], now: 2_000)

        let row = try #require(try await store.getById("photo-1"))
        #expect(MarkPhotoPaths.decode(row.photoPath) == ["marks/photo-1/a.jpg", "marks/photo-1/b.jpg"])
        #expect(row.photosUploadedLocal == false)
        #expect(row.photosUploadedCloud == false)
        #expect(row.uploadedLocal == true)
        #expect(row.uploadedCloud == true)
    }

    // MARK: - БОНУС-тесты (на Android покрыты только репо-тестами на фейках)

    @Test func addMember_setSemantics_appendsAndRecomputesComplete_resetsUploaded() async throws {
        let store = try makeStore()
        // Взятие, ждущее двух участников, с одним уже присутствующим и загруженное на оба таргета.
        try await store.upsert(Mark(
            id: "m1", raceId: 1, teamId: 7, checkpointId: 10, checkpointNumber: 10,
            cost: 5, method: "nfc", cpUid: "CPUID", cpCode: "CODE",
            present: [1],
            presentDetails: [MarkMemberSnapshot(numberInTeam: 1, nfcUid: "u1", number: 101)],
            expectedCount: 2, complete: false,
            takenAt: 1_000, updatedAt: 1_000,
            uploadedLocal: true, uploadedCloud: true
        ))

        try await store.addMember(
            id: "m1", numberInTeam: 2, nfcUid: "u2", number: 102, code: "C2",
            now: 5_000, expectedCount: 2
        )

        let row = try #require(try await store.getById("m1"))
        #expect(row.present == [1, 2])
        #expect(row.presentDetails?.map(\.numberInTeam) == [1, 2])
        #expect(row.presentDetails?.last == MarkMemberSnapshot(numberInTeam: 2, nfcUid: "u2", number: 102, code: "C2"))
        #expect(row.complete == true) // 2 >= expectedCount 2
        #expect(row.updatedAt == 5_000)
        // Мутация делает любую загруженную версию устаревшей.
        #expect(row.uploadedLocal == false)
        #expect(row.uploadedCloud == false)
    }

    @Test func addMember_duplicateNumberInTeam_isIdempotentNoOp() async throws {
        let store = try makeStore()
        try await store.upsert(Mark(
            id: "m1", raceId: 1, teamId: 7, checkpointId: 10, checkpointNumber: 10,
            cost: 5, method: "nfc", cpUid: "CPUID", cpCode: "CODE",
            present: [1],
            presentDetails: [MarkMemberSnapshot(numberInTeam: 1, nfcUid: "u1", number: 101)],
            expectedCount: 1, complete: true,
            takenAt: 1_000, updatedAt: 1_000,
            uploadedLocal: true, uploadedCloud: true
        ))

        // 1 уже в present — строка не трогается (updatedAt/uploaded* сохраняются).
        try await store.addMember(
            id: "m1", numberInTeam: 1, nfcUid: "u1", number: 101, code: nil,
            now: 9_000, expectedCount: 1
        )

        let row = try #require(try await store.getById("m1"))
        #expect(row.present == [1])
        #expect(row.updatedAt == 1_000)
        #expect(row.uploadedLocal == true)
        #expect(row.uploadedCloud == true)
    }

    @Test func addMember_onNullPresentDetails_startsFreshList() async throws {
        // Легаси-строка: present есть, presentDetails == nil (колонка предшествует снапшоту).
        let store = try makeStore()
        try await store.upsert(Mark(
            id: "m1", raceId: 1, teamId: 7, checkpointId: 10, checkpointNumber: 10,
            cost: 5, method: "nfc", cpUid: "CPUID", cpCode: "CODE",
            present: [1], presentDetails: nil,
            expectedCount: 2, complete: false,
            takenAt: 1_000, updatedAt: 1_000
        ))

        try await store.addMember(
            id: "m1", numberInTeam: 2, nfcUid: "u2", number: 102, code: nil,
            now: 5_000, expectedCount: 2
        )

        let row = try #require(try await store.getById("m1"))
        #expect(row.present == [1, 2])
        // Начинает свежий одноэлементный список вместо краша.
        #expect(row.presentDetails == [MarkMemberSnapshot(numberInTeam: 2, nfcUid: "u2", number: 102)])
    }

    @Test func addMember_missingRow_isNoOp() async throws {
        let store = try makeStore()
        try await store.addMember(
            id: "nope", numberInTeam: 1, nfcUid: "u", number: 1, code: nil,
            now: 5_000, expectedCount: 1
        )
        #expect(try await store.getById("nope") == nil)
    }

    @Test func attachLocation_writesLocColumns_resetsUploaded_leavesRest() async throws {
        let store = try makeStore()
        try await store.upsert(mark("nfc-1", method: "nfc", uploadedLocal: true, uploadedCloud: true))

        try await store.attachLocation(
            id: "nfc-1",
            lat: 55.75, lon: 37.61,
            accuracy: 4.5, altitude: 140.0, verticalAccuracy: 2.0,
            gpsTimeMs: 1_234, elapsedRealtimeAt: 9_999
        )

        let row = try #require(try await store.getById("nfc-1"))
        #expect(row.locLat == 55.75)
        #expect(row.locLon == 37.61)
        #expect(row.locAccuracy == 4.5)
        #expect(row.locAltitude == 140.0)
        #expect(row.locVerticalAccuracy == 2.0)
        #expect(row.locGpsTimeMs == 1_234)
        #expect(row.locElapsedRealtimeAt == 9_999)
        // Сброс uploaded* → строка пере-очередится, сервер получит анти-чит-координату.
        #expect(row.uploadedLocal == false)
        #expect(row.uploadedCloud == false)
        // present/complete/take-времена не тронуты column-scoped UPDATE'ом.
        #expect(row.present == [1])
        #expect(row.complete == true)
        #expect(row.takenAt == 1_000)
        #expect(row.updatedAt == 1_000)
    }

    @Test func attachLocation_missingRow_isNoOp() async throws {
        let store = try makeStore()
        try await store.attachLocation(
            id: "nope", lat: 1, lon: 2, accuracy: nil, altitude: nil,
            verticalAccuracy: nil, gpsTimeMs: nil, elapsedRealtimeAt: 1
        )
        #expect(try await store.getById("nope") == nil)
    }

    @Test func markUploadedIfUnchanged_flipsOnMatch_noOpsOnStale() async throws {
        let store = try makeStore()
        try await store.upsert(mark("m1", method: "nfc", updatedAt: 1_000))

        // Устаревший updatedAt (addMember промутировал между fetch и mark) — no-op.
        try await store.markUploadedLocalIfUnchanged(id: "m1", updatedAt: 999)
        #expect(try await store.getById("m1")?.uploadedLocal == false)

        // Совпадающий updatedAt — флипает.
        try await store.markUploadedLocalIfUnchanged(id: "m1", updatedAt: 1_000)
        try await store.markUploadedCloudIfUnchanged(id: "m1", updatedAt: 1_000)
        let row = try #require(try await store.getById("m1"))
        #expect(row.uploadedLocal == true)
        #expect(row.uploadedCloud == true)
    }

    @Test func markUploadedIfUnchangedAndNoLocation_guardsOnBothUpdatedAtAndNullLocation() async throws {
        let store = try makeStore()
        // Строка с координатой — guard `locLat IS NULL` должен провалить mark.
        try await store.upsert(mark("with-loc", method: "nfc", updatedAt: 1_000))
        try await store.attachLocation(
            id: "with-loc", lat: 55.0, lon: 37.0, accuracy: nil, altitude: nil,
            verticalAccuracy: nil, gpsTimeMs: nil, elapsedRealtimeAt: 1
        )
        // attachLocation сбросил uploaded* и bump'ов updatedAt не делает — updatedAt всё ещё 1000.
        try await store.markUploadedLocalIfUnchangedAndNoLocation(id: "with-loc", updatedAt: 1_000)
        #expect(try await store.getById("with-loc")?.uploadedLocal == false)

        // Строка без координаты — оба guard'а проходят, флипает.
        try await store.upsert(mark("no-loc", method: "nfc", updatedAt: 1_000))
        try await store.markUploadedLocalIfUnchangedAndNoLocation(id: "no-loc", updatedAt: 1_000)
        try await store.markUploadedCloudIfUnchangedAndNoLocation(id: "no-loc", updatedAt: 1_000)
        let row = try #require(try await store.getById("no-loc"))
        #expect(row.uploadedLocal == true)
        #expect(row.uploadedCloud == true)

        // Устаревший updatedAt на no-loc-строке — guard по updatedAt проваливает.
        try await store.upsert(mark("stale", method: "nfc", updatedAt: 1_000))
        try await store.markUploadedCloudIfUnchangedAndNoLocation(id: "stale", updatedAt: 999)
        #expect(try await store.getById("stale")?.uploadedCloud == false)
    }

    @Test func markUploadedLocalAndCloud_flipOnlyGivenIds() async throws {
        let store = try makeStore()
        try await store.upsert(mark("a", method: "nfc"))
        try await store.upsert(mark("b", method: "nfc"))
        try await store.upsert(mark("c", method: "nfc"))

        try await store.markUploadedLocal(ids: ["a", "c"])
        try await store.markUploadedCloud(ids: ["b"])

        #expect(try await store.getById("a")?.uploadedLocal == true)
        #expect(try await store.getById("b")?.uploadedLocal == false)
        #expect(try await store.getById("c")?.uploadedLocal == true)
        #expect(try await store.getById("a")?.uploadedCloud == false)
        #expect(try await store.getById("b")?.uploadedCloud == true)
    }

    @Test func markUploaded_emptyIds_isNoOp() async throws {
        let store = try makeStore()
        try await store.upsert(mark("a", method: "nfc"))
        // Пустой список — валидный `IN ()`-эквивалент GRDB, ничего не флипает.
        try await store.markUploadedLocal(ids: [])
        #expect(try await store.getById("a")?.uploadedLocal == false)
    }

    @Test func observeForTeam_ordersByTrustedTakenThenTakenDesc() async throws {
        let store = try makeStore()
        // trusted берётся, если есть, иначе wall (takenAt); DESC.
        try await store.upsert(Mark(
            id: "old", raceId: 1, teamId: 7, checkpointId: 1, checkpointNumber: 1,
            cost: 5, method: "nfc", cpUid: "", cpCode: "", present: [], expectedCount: 1,
            complete: false, takenAt: 100, updatedAt: 100, trustedTakenAt: 100
        ))
        try await store.upsert(Mark(
            id: "new", raceId: 1, teamId: 7, checkpointId: 2, checkpointNumber: 2,
            cost: 5, method: "nfc", cpUid: "", cpCode: "", present: [], expectedCount: 1,
            complete: false, takenAt: 999, updatedAt: 999, trustedTakenAt: 300
        ))
        // Без trusted — падаем на takenAt = 500.
        try await store.upsert(Mark(
            id: "mid", raceId: 1, teamId: 7, checkpointId: 3, checkpointNumber: 3,
            cost: 5, method: "nfc", cpUid: "", cpCode: "", present: [], expectedCount: 1,
            complete: false, takenAt: 500, updatedAt: 500, trustedTakenAt: nil
        ))

        let rows = try await firstValue(store.observeForTeam(7)).map(\.id)
        #expect(rows == ["mid", "new", "old"]) // 500, 300, 100 DESC
    }

    @Test func allIds_returnsEveryRowId() async throws {
        let store = try makeStore()
        try await store.upsert(mark("a", method: "nfc"))
        try await store.upsert(mark("b", method: "photo"))
        #expect(Set(try await store.allIds()) == ["a", "b"])
    }

    // MARK: - Зеркало PhotoPathsTest.kt (валидация формы пути)

    /// Зеркало `PhotoPathsTest.wrongShapeEntriesAreDropped` + whitespace-only сегменты
    /// (Kotlin `isBlank()` их отбрасывает — Swift-порт обязан вести себя так же).
    @Test func decode_dropsWrongShapeAndBlankSegments() {
        let raw = MarkPhotoPaths.encode([
            "other/m1/a.jpg",   // неправильный корень
            "marks/m1/a.png",   // неправильное расширение
            "marks/m1",         // слишком мало сегментов
            "marks/m1/sub/a.jpg", // слишком много сегментов
            "marks//a.jpg",     // пустой сегмент
            "marks/ /a.jpg",    // whitespace-only сегмент
            "marks/m1/a.jpg",   // единственный валидный
        ])
        #expect(MarkPhotoPaths.decode(raw) == ["marks/m1/a.jpg"])
    }

    @Test func isSafeRelativePhotoPath_rejectsWhitespaceOnlySegment() {
        #expect(!MarkPhotoPaths.isSafeRelativePhotoPath("marks/ /a.jpg")) // whitespace-only middle segment
        #expect(!MarkPhotoPaths.isSafeRelativePhotoPath("   ")) // whitespace-only path
        #expect(MarkPhotoPaths.isSafeRelativePhotoPath("marks/m1/a.jpg"))
    }
}
