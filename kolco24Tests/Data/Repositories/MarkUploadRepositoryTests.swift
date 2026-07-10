//
//  MarkUploadRepositoryTests.swift
//  kolco24Tests
//
//  Поведенческая спека движка дренажа выгрузки — зеркало Kotlin `MarkRepositoryUploadTest.kt`
//  (uploadLoop-семантика) поверх РЕАЛЬНОГО `MarkStore` над `AppDatabase.makeInMemory()` +
//  `FakeTransport` (конвенция этапов 2–5). Актор/стрим-специфика зеркала не имеет — тесты свежие.
//
//  **Ловушка `FakeTransport`:** это FIFO-очередь ответов по порядку ВЫЗОВОВ (не роутинг по URL), а
//  in-memory-граф даёт cloud и local ОДИН транспорт — ответы энкьюятся в порядке `flushScope`
//  (сначала все Local-батчи, затем Cloud; при нескольких скоупах — в порядке `pendingUploadScopes()`).
//  Многие тесты ставят `uploadedCloud = 1`, чтобы cloud-дренаж был пуст (returns nil, без транспорта)
//  и оставить в фокусе Local-цель.
//

import Foundation
import Testing
import GRDB
@testable import kolco24

struct MarkUploadRepositoryTests {

    // MARK: - Фикстуры

    private func makeMark(
        id: String,
        raceId: Int = 7,
        teamId: Int = 42,
        present: [Int] = [1],
        expectedCount: Int = 4,
        uploadedLocal: Bool = false,
        uploadedCloud: Bool = false,
        updatedAt: Int64 = 1000,
        takenAt: Int64 = 1000,
        locLat: Double? = nil
    ) -> Mark {
        Mark(
            id: id,
            raceId: raceId,
            teamId: teamId,
            checkpointId: 264,
            checkpointNumber: 12,
            cost: 5,
            method: "nfc",
            cpUid: "04A2B3C4D5E680",
            cpCode: "9f1a2b3c4d5e6f70",
            present: present,
            presentDetails: nil,
            expectedCount: expectedCount,
            complete: false,
            takenAt: takenAt,
            updatedAt: updatedAt,
            uploadedLocal: uploadedLocal,
            uploadedCloud: uploadedCloud,
            trustedTakenAt: nil,
            elapsedRealtimeAt: nil,
            bootCount: nil,
            locLat: locLat,
            locLon: locLat == nil ? nil : 37.61
        )
    }

    private func makeClient(
        base: String,
        transport: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) -> ApiClient {
        ApiClient(
            baseURL: base,
            keyId: "ios-v1",
            secret: "test-secret-123",
            installId: "install-abc",
            appVersion: "2.0.1",
            nowSeconds: { 1_700_000_000 },
            elapsedNowMs: { 0 },
            transport: transport
        )
    }

    /// Собрать граф: реальный `MarkStore` над in-memory БД + два `ApiClient`-а поверх ОДНОГО
    /// `FakeTransport` (in-memory-конвенция) + актор `MarkUploadRepository`.
    private func makeRepo(
        wallNow: @escaping () -> Int64 = { 5000 }
    ) throws -> (repo: MarkUploadRepository, store: MarkStore, transport: FakeTransport, db: AppDatabase) {
        let db = try AppDatabase.makeInMemory()
        let store = MarkStore(db.writer)
        let transport = FakeTransport()
        let cloud = makeClient(base: "https://cloud.test", transport: transport.handle)
        let local = makeClient(base: "http://local.test", transport: transport.handle)
        let repo = MarkUploadRepository(
            markStore: store, cloud: cloud, local: local, installId: "install-abc", wallNow: wallNow
        )
        return (repo, store, transport, db)
    }

    private func acceptedBody(_ ids: [String]) -> String {
        let joined = ids.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"accepted\":[\(joined)]}"
    }

    // MARK: - Happy path

    @Test func happyPath_bothTargets_flipFlags() async throws {
        let (repo, store, transport, _) = try makeRepo()
        try await store.upsert(makeMark(id: "m1"))
        // flushScope: Local-батч, затем Cloud-батч (по одному upload'у на цель; второй fetch пуст).
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["m1"])) // Local
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["m1"])) // Cloud

        await repo.uploadPending(raceId: 7, teamId: 42)

        let mark = try #require(try await store.getById("m1"))
        #expect(mark.uploadedLocal == true)
        #expect(mark.uploadedCloud == true)
        #expect(transport.callCount == 2)
    }

    // MARK: - Частичный accept (пересечение с батчем)

    @Test func partialAccept_marksOnlyAcceptedIntersectBatch() async throws {
        let (repo, store, transport, _) = try makeRepo()
        // Cloud уже доставлен → cloud-дренаж пуст, в фокусе Local.
        try await store.upsert(makeMark(id: "m1", uploadedCloud: true, takenAt: 1))
        try await store.upsert(makeMark(id: "m2", uploadedCloud: true, takenAt: 2))
        // Батч [m1, m2]; accepted = {m1, "ghost"} → помечен только m1, m2 остаётся pending.
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["m1", "ghost"]))
        // Второй проход: батч [m2]; accepted = {} → нет прогресса → стоп (.error), m2 не помечен.
        transport.enqueue(statusCode: 200, bodyString: acceptedBody([]))

        await repo.uploadPending(raceId: 7, teamId: 42)

        let m1 = try #require(try await store.getById("m1"))
        let m2 = try #require(try await store.getById("m2"))
        #expect(m1.uploadedLocal == true)
        #expect(m2.uploadedLocal == false)
    }

    // MARK: - Пустой accepted → стоп с .error, флаги нетронуты

    @Test func emptyAccepted_stopsWithError_flagsUntouched() async throws {
        let (repo, store, transport, _) = try makeRepo()
        try await store.upsert(makeMark(id: "m1", uploadedCloud: true))
        transport.enqueue(statusCode: 200, bodyString: acceptedBody([])) // Local: accepted пуст

        await repo.uploadPending(raceId: 7, teamId: 42)

        let mark = try #require(try await store.getById("m1"))
        #expect(mark.uploadedLocal == false)
        #expect(transport.callCount == 1) // один upload, стоп
        let outcome = await repo.outcomes[TrackScope(raceId: 7, teamId: 42)]?[.local]
        #expect(outcome?.kind == .error)
    }

    // MARK: - Офлайн (URLError) → флаги 0, исход .offline

    @Test func offline_urlError_leavesFlagsZero_outcomeOffline() async throws {
        let (repo, store, transport, _) = try makeRepo()
        try await store.upsert(makeMark(id: "m1", uploadedCloud: true))
        transport.enqueueError(URLError(.notConnectedToInternet)) // Local: транспортный обрыв

        await repo.uploadPending(raceId: 7, teamId: 42)

        let mark = try #require(try await store.getById("m1"))
        #expect(mark.uploadedLocal == false)
        #expect(transport.callCount == 1)
        let outcome = await repo.outcomes[TrackScope(raceId: 7, teamId: 42)]?[.local]
        #expect(outcome?.kind == .offline)
    }

    // MARK: - 403 → ровно один запрос (нет ретрая), исход .error

    @Test func forbidden403_noRetry_singleRequest_outcomeError() async throws {
        let (repo, store, transport, _) = try makeRepo()
        try await store.upsert(makeMark(id: "m1", uploadedCloud: true))
        transport.enqueue(statusCode: 403) // Local: forbidden

        await repo.uploadPending(raceId: 7, teamId: 42)

        let mark = try #require(try await store.getById("m1"))
        #expect(mark.uploadedLocal == false)
        #expect(transport.callCount == 1) // POST не ретраится
        let outcome = await repo.outcomes[TrackScope(raceId: 7, teamId: 42)]?[.local]
        #expect(outcome?.kind == .error)
    }

    // MARK: - Батчирование >500

    @Test func batching_over500Rows_multipleRequests_allFlagsSet() async throws {
        let (repo, store, transport, _) = try makeRepo()
        let ids = (0..<600).map { String(format: "m%03d", $0) }
        for (i, id) in ids.enumerated() {
            // Cloud уже доставлен → только Local-дренаж, чтобы счёт транспорта был про батчинг.
            try await store.upsert(makeMark(id: id, uploadedCloud: true, takenAt: Int64(i)))
        }
        // Каждый ответ несёт ВСЕ 600 id → пересечение с любым батчем корректно, без завязки на порядок.
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(ids)) // Local-батч 1 (500)
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(ids)) // Local-батч 2 (100)

        await repo.uploadPending(raceId: 7, teamId: 42)

        #expect(transport.callCount == 2) // 600 > 500 → два запроса
        for id in ids {
            let mark = try #require(try await store.getById(id))
            #expect(mark.uploadedLocal == true)
        }
    }

    // MARK: - Version-guard: updatedAt бампнут между fetch и mark

    @Test func versionGuard_updatedAtBumpedMidFlush_rowReUploaded() async throws {
        let db = try AppDatabase.makeInMemory()
        let store = MarkStore(db.writer)

        // Транспорт-хук: на ПЕРВОМ вызове бампит `updatedAt` (гонка с `addMember`) СЫРЫМ SQL — без сброса
        // флагов, чтобы cloud остался доставленным. Дальше — обычный 200. `calls` считает попытки.
        let calls = CallCounter()
        let racingTransport: (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            if calls.next() == 0 {
                try await db.writer.write { db in
                    try db.execute(sql: "UPDATE marks SET updatedAt = 2000 WHERE id = 'm1'")
                }
            }
            let body = Data(self.acceptedBody(["m1"]).utf8)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (body, resp)
        }
        let cloud = makeClient(base: "https://cloud.test", transport: racingTransport)
        let local = makeClient(base: "http://local.test", transport: racingTransport)
        let repo = MarkUploadRepository(
            markStore: store, cloud: cloud, local: local, installId: "install-abc", wallNow: { 5000 }
        )
        // has GPS → mark-путь чистого version-guard (`markUploadedLocalIfUnchanged`, без `AndNoLocation`).
        try await store.upsert(makeMark(id: "m1", uploadedCloud: true, updatedAt: 1000, locLat: 55.75))

        await repo.uploadPending(raceId: 7, teamId: 42)

        let mark = try #require(try await store.getById("m1"))
        // Первый mark(updatedAt=1000) не лёг (строка уже 2000) → перевыгрузка → второй mark(2000) лёг.
        #expect(mark.uploadedLocal == true)
        #expect(calls.value == 2) // ровно две попытки Local (перевыгрузка)
    }

    // MARK: - Version-guard: attachLocation (locLat) между fetch и mark

    @Test func versionGuard_locationAttachedMidFlush_rowReUploaded() async throws {
        let db = try AppDatabase.makeInMemory()
        let store = MarkStore(db.writer)

        let calls = CallCounter()
        let racingTransport: (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            if calls.next() == 0 {
                // Гонка с attachLocation: ставим фикс СЫРЫМ SQL (без сброса флагов/бампа updatedAt).
                try await db.writer.write { db in
                    try db.execute(sql: "UPDATE marks SET locLat = 55.75, locLon = 37.61 WHERE id = 'm1'")
                }
            }
            let body = Data(self.acceptedBody(["m1"]).utf8)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (body, resp)
        }
        let cloud = makeClient(base: "https://cloud.test", transport: racingTransport)
        let local = makeClient(base: "http://local.test", transport: racingTransport)
        let repo = MarkUploadRepository(
            markStore: store, cloud: cloud, local: local, installId: "install-abc", wallNow: { 5000 }
        )
        // locLat = nil → mark-путь `…IfUnchangedAndNoLocation`; фикс во время upload'а провалит `locLat IS NULL`.
        try await store.upsert(makeMark(id: "m1", uploadedCloud: true, updatedAt: 1000, locLat: nil))

        await repo.uploadPending(raceId: 7, teamId: 42)

        let mark = try #require(try await store.getById("m1"))
        #expect(mark.uploadedLocal == true)
        #expect(calls.value == 2) // перевыгрузка с координатой
    }

    // MARK: - Конкурентные uploadAllPending → один проход

    @Test func concurrentUploadAllPending_singlePass() async throws {
        let (repo, store, transport, _) = try makeRepo()
        try await store.upsert(makeMark(id: "m1"))
        // Ровно один проход: Local + Cloud. Если бы guard не сработал, второй проход опустошил бы
        // очередь → precondition-краш в FakeTransport.
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["m1"]))
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["m1"]))

        async let a: Void = repo.uploadAllPending()
        async let b: Void = repo.uploadAllPending()
        _ = await (a, b)

        #expect(transport.callCount == 2)
        let mark = try #require(try await store.getById("m1"))
        #expect(mark.uploadedLocal == true)
        #expect(mark.uploadedCloud == true)
    }

    // MARK: - uploadAllPending обходит все скоупы

    @Test func uploadAllPending_walksEveryPendingScope() async throws {
        let (repo, store, transport, _) = try makeRepo()
        try await store.upsert(makeMark(id: "m1", teamId: 1))
        try await store.upsert(makeMark(id: "m2", teamId: 2))
        // Порядок скоупов из `SELECT DISTINCT` не гарантирован → каждый ответ несёт ОБА id, пересечение
        // с одно-марковым батчем скоупа даёт верный id. 2 скоупа × 2 цели = 4 запроса.
        for _ in 0..<4 {
            transport.enqueue(statusCode: 200, bodyString: acceptedBody(["m1", "m2"]))
        }

        await repo.uploadAllPending()

        let m1 = try #require(try await store.getById("m1"))
        let m2 = try #require(try await store.getById("m2"))
        #expect(m1.uploadedLocal == true && m1.uploadedCloud == true)
        #expect(m2.uploadedLocal == true && m2.uploadedCloud == true)
        #expect(transport.callCount == 4)
    }

    // MARK: - drainUploadLoop: ошибка БД (fetch/mark бросили) → .error + лог

    /// `fetch` бросил (SQL-ошибка) → цикл сворачивает в `.error`, не роняя процесс. Прямой тест
    /// generic-цикла — семантика «ошибка БД → .error» из спеки не зависит от конкретного store'а.
    @Test func drainLoop_fetchThrows_returnsError() async {
        struct Boom: Error {}
        let result = await drainUploadLoop(
            fetch: { () async throws -> [String] in throw Boom() },
            id: { $0 },
            upload: { _ in PostResult<[String]>.success([]) },
            mark: { _, _ in }
        )
        #expect(result == .error)
    }

    /// `mark` бросил после успешного POST (гонка/SQL-ошибка при пометке) → `.error`; `fetch` при этом
    /// дёрнут ровно один раз (после броска цикл выходит, не зациклившись на непустом батче).
    @Test func drainLoop_markThrows_returnsError() async {
        struct Boom: Error {}
        let calls = CallCounter()
        let result = await drainUploadLoop(
            fetch: { () async throws -> [String] in _ = calls.next(); return ["a"] },
            id: { $0 },
            upload: { _ in PostResult<[String]>.success(["a"]) },
            mark: { _, _ in throw Boom() }
        )
        #expect(result == .error)
        #expect(calls.value == 1)
    }

    /// Через актор: mark-UPDATE бросает (таблица `marks` уронена гонкой во время POST) → исход цели
    /// `.error`, актор переживает ошибку БД (доходим до ассертов, краша нет).
    @Test func dbError_duringMark_recordsErrorOutcome_actorSurvives() async throws {
        let db = try AppDatabase.makeInMemory()
        let store = MarkStore(db.writer)

        let calls = CallCounter()
        // На первом POST'е роняем таблицу marks (гонка «ошибка БД») — последующий mark-UPDATE бросит.
        let droppingTransport: (URLRequest) async throws -> (Data, HTTPURLResponse) = { request in
            if calls.next() == 0 {
                try await db.writer.write { db in
                    try db.execute(sql: "DROP TABLE marks")
                }
            }
            let body = Data(self.acceptedBody(["m1"]).utf8)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (body, resp)
        }
        let cloud = makeClient(base: "https://cloud.test", transport: droppingTransport)
        let local = makeClient(base: "http://local.test", transport: droppingTransport)
        let repo = MarkUploadRepository(
            markStore: store, cloud: cloud, local: local, installId: "install-abc", wallNow: { 5000 }
        )
        // Cloud уже доставлен → в фокусе Local: fetch пройдёт, POST уронит таблицу, mark бросит.
        try await store.upsert(makeMark(id: "m1", uploadedCloud: true))

        await repo.uploadPending(raceId: 7, teamId: 42) // не роняет процесс

        let outcome = await repo.outcomes[TrackScope(raceId: 7, teamId: 42)]?[.local]
        #expect(outcome?.kind == .error)
        #expect(calls.value == 1) // fetch прошёл, mark бросил — ретрая POST нет
    }

    // MARK: - Нечего слать → 0 запросов, исход не пишется (nil-ветка)

    /// Полностью выгруженный скоуп: оба `fetch`а сразу пусты → `drainUploadLoop` возвращает `nil` →
    /// `combineOutcome(nil, nil) == nil` → `recordOutcome` не зовётся. Ни одного запроса, словарь исходов пуст.
    @Test func nothingToSend_noRequest_noOutcomeRecorded() async throws {
        let (repo, store, transport, _) = try makeRepo()
        try await store.upsert(makeMark(id: "m1", uploadedLocal: true, uploadedCloud: true))

        await repo.uploadPending(raceId: 7, teamId: 42)

        #expect(transport.callCount == 0) // fetch'и пусты — POST'а нет
        let byTarget = await repo.outcomes[TrackScope(raceId: 7, teamId: 42)]
        #expect(byTarget == nil) // ни .ok, ни .error — исход не записан
    }

    // MARK: - Исход попадает в стрим

    @Test func outcome_reachesUpdatesStream() async throws {
        let (repo, store, transport, _) = try makeRepo()
        try await store.upsert(makeMark(id: "m1", uploadedCloud: true))
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["m1"])) // Local .ok

        await repo.uploadPending(raceId: 7, teamId: 42)

        // bufferingNewest(1) держит последний снимок до подписки — забираем первый эмит.
        var received: [TrackScope: [UploadTarget: TargetUploadOutcome]]?
        for await snapshot in repo.outcomeUpdates {
            received = snapshot
            break
        }
        let outcome = received?[TrackScope(raceId: 7, teamId: 42)]?[.local]
        #expect(outcome?.kind == .ok)
        #expect(outcome?.atWallMs == 5000)
    }

    // MARK: - Frame-дренаж (этап 7) — зеркала `MarkRepositoryUploadTest.kt`

    /// Фото-марка с кадрами, метаданные уже доставлены (`uploaded* = 1`) → фокус дренажа на кадрах.
    private func makePhotoMark(
        id: String,
        raceId: Int = 1,
        teamId: Int = 7,
        paths: [String],
        uploadedLocal: Bool = true,
        uploadedCloud: Bool = true,
        takenAt: Int64 = 2000,
        updatedAt: Int64 = 2000
    ) -> Mark {
        Mark(
            id: id, raceId: raceId, teamId: teamId,
            checkpointId: 20, checkpointNumber: 20, cost: 0,
            method: "photo", cpUid: "", cpCode: "",
            present: [], presentDetails: nil,
            expectedCount: 3, complete: true,
            photoPath: PhotoPaths.encode(paths),
            takenAt: takenAt, updatedAt: updatedAt,
            uploadedLocal: uploadedLocal, uploadedCloud: uploadedCloud,
            photosUploadedLocal: false, photosUploadedCloud: false
        )
    }

    /// Собрать граф с frame-роутинг-транспортом + fake file reader.
    private func makeFrameRepo(
        reader: FakeFrameReader,
        transport: FrameRoutingTransport,
        wallNow: @escaping () -> Int64 = { 5000 }
    ) throws -> (repo: MarkUploadRepository, store: MarkStore) {
        let db = try AppDatabase.makeInMemory()
        let store = MarkStore(db.writer)
        let cloud = makeClient(base: "https://cloud.test", transport: transport.handle)
        let local = makeClient(base: "http://local.test", transport: transport.handle)
        let repo = MarkUploadRepository(
            markStore: store, cloud: cloud, local: local,
            installId: "install-abc", wallNow: wallNow,
            frameReader: reader.read
        )
        return (repo, store)
    }

    @Test func frameDrain_metadataFirstOrdering_noFramePostWhileMetadataPending() async throws {
        // Метаданные ещё не выгружены (uploaded* = false) — их цикл падает Offline и не флипается;
        // `framePending*` гейтит на uploadedX = 1, так что кадровый аплоадер не должен дёрнуться.
        let reader = FakeFrameReader(); reader.put("marks/m/f1.jpg")
        let transport = FrameRoutingTransport()
        transport.onMetadata = { _, _ in .offline }
        let (repo, store) = try makeFrameRepo(reader: reader, transport: transport)
        try await store.upsert(makePhotoMark(id: "p1", paths: ["marks/m/f1.jpg"],
                                             uploadedLocal: false, uploadedCloud: false))

        await repo.uploadPending(raceId: 1, teamId: 7)

        #expect(transport.frameCalls.isEmpty)
        let mark = try #require(try await store.getById("p1"))
        #expect(mark.photosUploadedLocal == false)
        #expect(mark.photosUploadedCloud == false)
    }

    @Test func frameDrain_allFramesAccepted_flipsPhotosUploadedBothTargets() async throws {
        let paths = ["marks/m/f1.jpg", "marks/m/f2.jpg"]
        let reader = FakeFrameReader(); paths.forEach { reader.put($0) }
        let transport = FrameRoutingTransport() // default: every frame 200
        let (repo, store) = try makeFrameRepo(reader: reader, transport: transport)
        try await store.upsert(makePhotoMark(id: "p1", paths: paths))

        await repo.uploadPending(raceId: 1, teamId: 7)

        let mark = try #require(try await store.getById("p1"))
        #expect(mark.photosUploadedLocal == true)
        #expect(mark.photosUploadedCloud == true)
        let expected = Set(paths.map(PhotoPaths.frameIdOf))
        #expect(Set(transport.cloudFrameCalls.map(\.frameId)) == expected)
        #expect(Set(transport.localFrameCalls.map(\.frameId)) == expected)
    }

    @Test func frameDrain_transientFailure_stopsTargetBeforeLaterMarks_retriedNextTrigger() async throws {
        let reader = FakeFrameReader(); reader.put("marks/a/f1.jpg"); reader.put("marks/b/f1.jpg")
        let transport = FrameRoutingTransport()
        let offline = OfflineToggle(on: true)
        // Только облачные кадры под toggle; local держим полностью доставленным (нет кадрового дренажа).
        transport.onFrame = { call in
            guard call.isCloud else { return .status(200) }
            return offline.isOn ? .offline : .status(200)
        }
        let (repo, store) = try makeFrameRepo(reader: reader, transport: transport)
        // local уже доставлен → local frame-дренаж пуст; фокус на cloud.
        try await store.upsert(makePhotoMark(id: "a", paths: ["marks/a/f1.jpg"], takenAt: 1, updatedAt: 1))
        try await store.upsert(makePhotoMark(id: "b", paths: ["marks/b/f1.jpg"], takenAt: 2, updatedAt: 2))
        // Отметки уже загружены local → чтобы local-frame был пуст, ставим photosUploadedLocal сразу.
        try await store.setPhotosUploadedLocalIfUnchanged(id: "a", updatedAt: 1)
        try await store.setPhotosUploadedLocalIfUnchanged(id: "b", updatedAt: 2)

        await repo.uploadPending(raceId: 1, teamId: 7)

        // Первая (по порядку — «a») марка падает транзиентно → весь cloud-таргет стоп; «b» не пробуют.
        #expect(transport.cloudFrameCalls.count == 1)
        let a1 = try #require(try await store.getById("a"))
        let b1 = try #require(try await store.getById("b"))
        #expect(a1.photosUploadedCloud == false)
        #expect(b1.photosUploadedCloud == false)

        offline.isOn = false
        await repo.uploadPending(raceId: 1, teamId: 7)

        let a2 = try #require(try await store.getById("a"))
        let b2 = try #require(try await store.getById("b"))
        #expect(a2.photosUploadedCloud == true)
        #expect(b2.photosUploadedCloud == true)
    }

    @Test func frameDrain_hardFailureOnOneMark_leavesItPending_laterGoodMarkStillFlips() async throws {
        let reader = FakeFrameReader(); reader.put("marks/bad/f1.jpg"); reader.put("marks/good/f1.jpg")
        let transport = FrameRoutingTransport()
        transport.onFrame = { call in
            guard call.isCloud else { return .status(200) }
            return call.markId == "bad" ? .status(400) : .status(200)
        }
        let (repo, store) = try makeFrameRepo(reader: reader, transport: transport)
        try await store.upsert(makePhotoMark(id: "bad", paths: ["marks/bad/f1.jpg"], takenAt: 1, updatedAt: 1))
        try await store.upsert(makePhotoMark(id: "good", paths: ["marks/good/f1.jpg"], takenAt: 2, updatedAt: 2))
        try await store.setPhotosUploadedLocalIfUnchanged(id: "bad", updatedAt: 1)
        try await store.setPhotosUploadedLocalIfUnchanged(id: "good", updatedAt: 2)

        await repo.uploadPending(raceId: 1, teamId: 7)

        let bad = try #require(try await store.getById("bad"))
        let good = try #require(try await store.getById("good"))
        #expect(bad.photosUploadedCloud == false)
        #expect(good.photosUploadedCloud == true)
        // «good» флипается, но не маскирует застрявший ядовитый кадр «bad»: общий исход — Error.
        let outcome = await repo.outcomes[TrackScope(raceId: 1, teamId: 7)]?[.cloud]
        #expect(outcome?.kind == .error)
    }

    @Test func frameDrain_payloadTooLargeOnOneMark_leavesItPending_laterGoodMarkStillFlips() async throws {
        let reader = FakeFrameReader(); reader.put("marks/bad/f1.jpg"); reader.put("marks/good/f1.jpg")
        let transport = FrameRoutingTransport()
        transport.onFrame = { call in
            guard call.isCloud else { return .status(200) }
            return call.markId == "bad" ? .status(413) : .status(200)
        }
        let (repo, store) = try makeFrameRepo(reader: reader, transport: transport)
        try await store.upsert(makePhotoMark(id: "bad", paths: ["marks/bad/f1.jpg"], takenAt: 1, updatedAt: 1))
        try await store.upsert(makePhotoMark(id: "good", paths: ["marks/good/f1.jpg"], takenAt: 2, updatedAt: 2))
        try await store.setPhotosUploadedLocalIfUnchanged(id: "bad", updatedAt: 1)
        try await store.setPhotosUploadedLocalIfUnchanged(id: "good", updatedAt: 2)

        await repo.uploadPending(raceId: 1, teamId: 7)

        let bad = try #require(try await store.getById("bad"))
        let good = try #require(try await store.getById("good"))
        #expect(bad.photosUploadedCloud == false)
        #expect(good.photosUploadedCloud == true)
        let outcome = await repo.outcomes[TrackScope(raceId: 1, teamId: 7)]?[.cloud]
        #expect(outcome?.kind == .error)
    }

    @Test func frameDrain_missingFile_keepsMarkPending_drainTerminatesWithoutSpinning() async throws {
        let reader = FakeFrameReader() // файла нет → read == nil
        let transport = FrameRoutingTransport()
        let (repo, store) = try makeFrameRepo(reader: reader, transport: transport)
        try await store.upsert(makePhotoMark(id: "p1", paths: ["marks/m/f1.jpg"], uploadedLocal: true, uploadedCloud: true))

        await repo.uploadPending(raceId: 1, teamId: 7) // должен завершиться, не зациклиться

        let mark = try #require(try await store.getById("p1"))
        #expect(mark.photosUploadedCloud == false)
        #expect(transport.frameCalls.isEmpty) // POST для нечитаемого кадра даже не пробуют
    }

    @Test func frameDrain_dualTargetIndependence_lanOfflineCloudStillFlips() async throws {
        let reader = FakeFrameReader(); reader.put("marks/m/f1.jpg")
        let transport = FrameRoutingTransport()
        transport.onFrame = { call in call.isCloud ? .status(200) : .offline } // local Offline
        let (repo, store) = try makeFrameRepo(reader: reader, transport: transport)
        try await store.upsert(makePhotoMark(id: "p1", paths: ["marks/m/f1.jpg"]))

        await repo.uploadPending(raceId: 1, teamId: 7)

        let mark = try #require(try await store.getById("p1"))
        #expect(mark.photosUploadedCloud == true)
        #expect(mark.photosUploadedLocal == false)
    }

    @Test func frameDrain_attachPhotos_requeuesFrames() async throws {
        let reader = FakeFrameReader(); reader.put("marks/m/f1.jpg"); reader.put("marks/m/f2.jpg")
        let transport = FrameRoutingTransport()
        let (repo, store) = try makeFrameRepo(reader: reader, transport: transport)
        try await store.upsert(makePhotoMark(id: "p1", paths: ["marks/m/f1.jpg"]))
        await repo.uploadPending(raceId: 1, teamId: 7)
        #expect(try await store.getById("p1")?.photosUploadedCloud == true)

        let bumped = (try await store.getById("p1"))!.updatedAt + 1000
        try await store.attachPhotos(id: "p1", newPaths: ["marks/m/f2.jpg"], now: bumped)

        let after = try #require(try await store.getById("p1"))
        #expect(after.photosUploadedCloud == false) // attachPhotos сбросил флаги
        #expect(after.photosUploadedLocal == false)

        await repo.uploadPending(raceId: 1, teamId: 7)

        let final = try #require(try await store.getById("p1"))
        #expect(final.photosUploadedCloud == true)
        #expect(final.photosUploadedLocal == true)
        #expect(transport.cloudFrameCalls.contains { $0.frameId == PhotoPaths.frameIdOf("marks/m/f2.jpg") })
    }

    @Test func frameDrain_attachPhotosRacingMidDrainFlip_doesNotStrandNewFrame() async throws {
        // Version-guard-гонка: дренаж захватил марку (устаревший updatedAt), затем — во время выгрузки
        // её единственного кадра — attachPhotos дописывает новый кадр и бампит updatedAt. Guard-нутый
        // setPhotosUploadedCloudIfUnchanged(id, staleUpdatedAt) должен НЕ флипнуть (mismatch), а
        // re-fetch цикла подберёт всё ещё-pending марку и дошлёт f1 (идемпотентно) + новый f2.
        let reader = FakeFrameReader(); reader.put("marks/m/f1.jpg"); reader.put("marks/m/f2.jpg")
        let db = try AppDatabase.makeInMemory()
        let store = MarkStore(db.writer)
        let transport = FrameRoutingTransport()
        let raced = OfflineToggle(on: false) // переиспользуем как «уже сгонял?»
        transport.onFrame = { [store] call in
            guard call.isCloud else { return .offline } // local не мешает
            if !raced.isOn {
                raced.isOn = true
                let now = ((try? await store.getById("p1"))??.updatedAt ?? 2000) + 1000
                try? await store.attachPhotos(id: "p1", newPaths: ["marks/m/f2.jpg"], now: now)
            }
            return .status(200)
        }
        let cloud = makeClient(base: "https://cloud.test", transport: transport.handle)
        let local = makeClient(base: "http://local.test", transport: transport.handle)
        let repo = MarkUploadRepository(
            markStore: store, cloud: cloud, local: local,
            installId: "install-abc", wallNow: { 5000 }, frameReader: reader.read
        )
        try await store.upsert(makePhotoMark(id: "p1", paths: ["marks/m/f1.jpg"]))

        await repo.uploadPending(raceId: 1, teamId: 7)

        #expect(raced.isOn)
        let mark = try #require(try await store.getById("p1"))
        #expect(mark.photosUploadedCloud == true) // сошлось без застревания
        #expect(transport.cloudFrameCalls.contains { $0.frameId == PhotoPaths.frameIdOf("marks/m/f1.jpg") })
        #expect(transport.cloudFrameCalls.contains { $0.frameId == PhotoPaths.frameIdOf("marks/m/f2.jpg") })
    }

    @Test func frameDrain_combinedOutcome_metadataErrorFrameOk_finalOutcomeNotOk() async throws {
        let reader = FakeFrameReader(); reader.put("marks/m/f1.jpg")
        let transport = FrameRoutingTransport()
        // Метаданные (nfc-марка) на cloud → 403 (Error); кадр фото-марки → 200.
        transport.onMetadata = { isCloud, _ in isCloud ? .status(403) : .offline }
        transport.onFrame = { _ in .status(200) }
        let (repo, store) = try makeFrameRepo(reader: reader, transport: transport)
        // nfc-марка, метаданные не выгружены (упадут); фото-марка с доставленными метаданными + 1 кадр.
        try await store.upsert(makeMark(id: "nfc1", raceId: 1, teamId: 7, uploadedLocal: false, uploadedCloud: false, takenAt: 1))
        try await store.upsert(makePhotoMark(id: "photo1", paths: ["marks/m/f1.jpg"], takenAt: 2, updatedAt: 2))

        await repo.uploadPending(raceId: 1, teamId: 7)

        // Кадр сам по себе прошёл...
        #expect(try await store.getById("photo1")?.photosUploadedCloud == true)
        // ...но комбинированный per-target исход не должен читаться Ok: metadata Error приоритетнее.
        let outcome = await repo.outcomes[TrackScope(raceId: 1, teamId: 7)]?[.cloud]
        #expect(outcome?.kind == .error)
    }
}

// MARK: - Хелперы frame-дренажа

/// Fake-читатель байт кадра: отдаёт то, что было `put`; никогда не `put` путь → `nil` (missing file).
final class FakeFrameReader: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]

    func put(_ path: String, bytes: Data = Data([1, 2, 3])) {
        lock.lock(); defer { lock.unlock() }
        files[path] = bytes
    }

    func read(_ relPath: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return files[relPath]
    }
}

/// Мутабельный флаг под замком (переключение поведения транспорта между триггерами / гонка).
final class OfflineToggle: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(on: Bool) { value = on }
    var isOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}

/// Роутинг-транспорт: различает metadata-POST (`…/marks/`) и frame-POST (`…/mark/<id>/photo/<fid>`)
/// по пути и cloud/local по хосту; исходы задаются per-test замыканиями. Записывает frame-вызовы.
final class FrameRoutingTransport: @unchecked Sendable {
    struct FrameCall: Equatable, Sendable {
        let isCloud: Bool
        let markId: String
        let frameId: String
    }

    enum Response { case status(Int); case ok(accepted: [String]); case offline }

    private let lock = NSLock()
    private var _frameCalls: [FrameCall] = []
    var frameCalls: [FrameCall] { lock.lock(); defer { lock.unlock() }; return _frameCalls }
    var cloudFrameCalls: [FrameCall] { frameCalls.filter { $0.isCloud } }
    var localFrameCalls: [FrameCall] { frameCalls.filter { !$0.isCloud } }

    /// Метаданный ответ по (isCloud, ids батча). Дефолт — принять всё.
    var onMetadata: (_ isCloud: Bool, _ ids: [String]) async -> Response = { _, ids in .ok(accepted: ids) }
    /// Кадровый ответ по вызову. Дефолт — 200.
    var onFrame: (_ call: FrameCall) async -> Response = { _ in .status(200) }

    func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let isCloud = (url.host == "cloud.test")
        let segs = url.path.split(separator: "/").map(String.init)
        let response: Response
        if let mi = segs.firstIndex(of: "mark"), let pi = segs.firstIndex(of: "photo"),
           mi + 1 < segs.count, pi + 1 < segs.count {
            let call = FrameCall(isCloud: isCloud, markId: segs[mi + 1], frameId: segs[pi + 1])
            lock.lock(); _frameCalls.append(call); lock.unlock()
            response = await onFrame(call)
        } else {
            response = await onMetadata(isCloud, Self.parseIds(request.httpBody))
        }
        guard let built = Self.build(response, url: url) else {
            throw URLError(.notConnectedToInternet)
        }
        return built
    }

    private static func parseIds(_ body: Data?) -> [String] {
        guard let body,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let marks = obj["marks"] as? [[String: Any]] else { return [] }
        return marks.compactMap { $0["id"] as? String }
    }

    /// `nil` возвращается для `.offline` — вызывающий бросает `URLError`.
    private static func build(_ response: Response, url: URL) -> (Data, HTTPURLResponse)? {
        switch response {
        case .offline:
            return nil
        case .status(let code):
            let resp = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (Data(), resp)
        case .ok(let accepted):
            let joined = accepted.map { "\"\($0)\"" }.joined(separator: ",")
            let body = Data("{\"accepted\":[\(joined)]}".utf8)
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (body, resp)
        }
    }
}

// MARK: - isHardFrameFailure — зеркало `IsHardFrameFailureTest.kt`

struct IsHardFrameFailureTests {
    @Test func badRequest_isHard() {
        #expect(isHardFrameFailure(PostResult<Void>.badRequest) == true)
    }

    @Test func payloadTooLarge413_isHard() {
        #expect(isHardFrameFailure(PostResult<Void>.error(code: 413)) == true)
    }

    @Test func otherErrorCodes_areTransient() {
        #expect(isHardFrameFailure(PostResult<Void>.error(code: 500)) == false)
        #expect(isHardFrameFailure(PostResult<Void>.error(code: nil)) == false)
    }

    @Test func targetWideFailures_areTransient() {
        #expect(isHardFrameFailure(PostResult<Void>.offline) == false)
        #expect(isHardFrameFailure(PostResult<Void>.unauthorized) == false)
        #expect(isHardFrameFailure(PostResult<Void>.forbidden) == false)
        #expect(isHardFrameFailure(PostResult<Void>.conflict) == false)
        #expect(isHardFrameFailure(PostResult<Void>.rateLimited) == false)
    }
}
