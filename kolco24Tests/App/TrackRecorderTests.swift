//
//  TrackRecorderTests.swift
//  kolco24Tests
//
//  Поведенческая спека `TrackRecorder` (этап 8) — зеркала нет (Android-`TrackRecordingService` — сервис),
//  тесты свежие поверх РЕАЛЬНЫХ `TrackStore`/`TrackUploadRepository`/`MarkUploadRepository` над
//  `AppDatabase.makeInMemory()` + скриптованный `FakeTrackEngine` + управляемое время (идиома `ScanModel`).
//
//  Транспорт — роутящий (не FIFO): POST `…/track/` и `…/marks/` эхом отдают принятые id, всё прочее 304;
//  так live-upload на любом фиксе обрабатывается без precondition-краша пустой очереди.
//

import Foundation
import Testing
import GRDB
@testable import kolco24

@MainActor
struct TrackRecorderTests {

    // MARK: - Фейки/хелперы

    /// Скриптованный движок: `emit`/`finish`/`stop`; помнит, останавливали ли его.
    final class FakeTrackEngine: TrackEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: AsyncStream<RawFix>.Continuation?
        private var _stopped = false
        var stopped: Bool { lock.lock(); defer { lock.unlock() }; return _stopped }

        func fixes() -> AsyncStream<RawFix> {
            AsyncStream { cont in
                lock.lock(); continuation?.finish(); continuation = cont; lock.unlock()
            }
        }

        func emit(_ fix: RawFix) {
            lock.lock(); let c = continuation; lock.unlock()
            c?.yield(fix)
        }

        func stop() {
            lock.lock(); _stopped = true; let c = continuation; continuation = nil; lock.unlock()
            c?.finish()
        }

        /// Завершить стрим БЕЗ пометки `stopped` — эмулирует «движок сам закрыл поток» (отзыв геодоступа /
        /// ошибка CoreLocation), т.е. завершение НЕ через `stop()` рекордера.
        func finish() {
            lock.lock(); let c = continuation; continuation = nil; lock.unlock()
            c?.finish()
        }
    }

    /// Детерминированный генератор id: сегмент = «id-0», далее точки «id-1», «id-2»…
    final class IdGen: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> String { lock.lock(); defer { lock.unlock() }; let v = "id-\(n)"; n += 1; return v }
    }

    /// Роутящий транспорт: `…/track/` и `…/marks/` → 200 `{"accepted":[<id из тела>]}`; прочее → 304.
    final class RoutingTransport: @unchecked Sendable {
        private let lock = NSLock()
        private var _recorded: [URLRequest] = []
        var recorded: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _recorded }
        var callCount: Int { recorded.count }

        func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.lock(); _recorded.append(request); lock.unlock()
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("/track/") {
                return Self.ok(request, Self.postedIds(request.httpBody, key: "points"))
            }
            if url.hasSuffix("/marks/") {
                return Self.ok(request, Self.postedIds(request.httpBody, key: "marks"))
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (Data(), resp)
        }

        private static func ok(_ request: URLRequest, _ ids: [String]) -> (Data, HTTPURLResponse) {
            let joined = ids.map { "\"\($0)\"" }.joined(separator: ",")
            let body = Data("{\"accepted\":[\(joined)]}".utf8)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (body, resp)
        }

        private static func postedIds(_ body: Data?, key: String) -> [String] {
            guard let body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let items = json[key] as? [[String: Any]]
            else { return [] }
            return items.compactMap { $0["id"] as? String }
        }

        /// Все id точек трека, ушедшие в какой-либо POST `…/track/` (детерминированная проверка троттлинга —
        /// без sleep-таймингов: троттлинг держит ⇔ id точки НЕ появился ни в одном запросе).
        var postedTrackPointIds: [String] {
            recorded.flatMap { req -> [String] in
                guard req.url?.absoluteString.hasSuffix("/track/") == true else { return [] }
                return Self.postedIds(req.httpBody, key: "points")
            }
        }
    }

    private func makeClient(_ base: String, _ transport: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse)) -> ApiClient {
        ApiClient(
            baseURL: base, keyId: "ios-v1", secret: "test-secret-123", installId: "install-abc",
            appVersion: "2.0.1", nowSeconds: { 1_700_000_000 }, elapsedNowMs: { 0 }, transport: transport
        )
    }

    /// Минимальное pending-взятие (raceId/teamId по умолчанию совпадают со скоупом записи) — чтобы
    /// проверить пиггибек выгрузки взятий на GPS-пробуждении/стопе.
    private func makeMark(id: String, raceId: Int = 7, teamId: Int = 42) -> Mark {
        Mark(
            id: id, raceId: raceId, teamId: teamId, checkpointId: 264, checkpointNumber: 12, cost: 5,
            method: "nfc", cpUid: "04A2B3C4D5E680", cpCode: "9f1a2b3c4d5e6f70", present: [1],
            presentDetails: nil, expectedCount: 4, complete: false, takenAt: 1000, updatedAt: 1000,
            uploadedLocal: false, uploadedCloud: false, trustedTakenAt: nil, elapsedRealtimeAt: nil,
            bootCount: nil, locLat: nil, locLon: nil
        )
    }

    private func mark(_ db: AppDatabase, id: String) async throws -> Mark? {
        try await db.writer.read { db in
            try Mark.fetchOne(db, sql: "SELECT * FROM marks WHERE id = ?", arguments: [id])
        }
    }

    private func makeFix(elapsedMs: Int64, lat: Double = 55.0, lon: Double = 37.0, gpsMs: Int64 = 1) -> RawFix {
        RawFix(
            lat: lat, lon: lon, accuracy: 5, altitude: nil, verticalAccuracyMeters: nil,
            gpsTimeMs: gpsMs, elapsedRealtimeNanos: elapsedMs * 1_000_000
        )
    }

    private struct Rig {
        let recorder: TrackRecorder
        let engine: FakeTrackEngine
        let transport: RoutingTransport
        let trackStore: TrackStore
        let markStore: MarkStore
        let db: AppDatabase
    }

    private func makeRig(
        clock: TrustedClock = AppEnvironment.makeTestClock(),
        hasAccess: Bool = true,
        onGeoDenied: (() -> Void)? = nil,
        onRequestAuth: (() -> Void)? = nil,
        wall: Int64 = 2_000_000,
        elapsed: Int64 = 6_000,
        ids: IdGen = IdGen()
    ) throws -> Rig {
        let db = try AppDatabase.makeInMemory()
        let trackStore = TrackStore(db.writer)
        let markStore = MarkStore(db.writer)
        let transport = RoutingTransport()
        let cloud = makeClient("https://cloud.test", transport.handle)
        let local = makeClient("http://local.test", transport.handle)
        let trackRepo = TrackUploadRepository(trackStore: trackStore, cloud: cloud, local: local, wallNow: { 5000 })
        let markRepo = MarkUploadRepository(markStore: markStore, cloud: cloud, local: local, installId: "i", wallNow: { 5000 })
        let engine = FakeTrackEngine()
        let rec = TrackRecorder(
            trackStore: trackStore, trackUploadRepository: trackRepo, markUploadRepository: markRepo,
            trustedClock: clock, makeEngine: { engine }, hasLocationAccess: { hasAccess },
            requestAuthorization: onRequestAuth ?? {},
            wallNow: { wall }, elapsedNow: { elapsed }, bootCount: { nil }, idFactory: ids.next
        )
        rec.onGeoDenied = onGeoDenied
        return Rig(recorder: rec, engine: engine, transport: transport, trackStore: trackStore, markStore: markStore, db: db)
    }

    private func allPoints(_ db: AppDatabase, raceId: Int = 7, teamId: Int = 42) async throws -> [TrackPoint] {
        try await db.writer.read { db in
            try TrackPoint.fetchAll(
                db,
                sql: "SELECT * FROM track_points WHERE raceId = ? AND teamId = ? ORDER BY elapsedRealtimeAt, id",
                arguments: [raceId, teamId]
            )
        }
    }

    private func point(_ db: AppDatabase, id: String) async throws -> TrackPoint? {
        try await db.writer.read { db in
            try TrackPoint.fetchOne(db, sql: "SELECT * FROM track_points WHERE id = ?", arguments: [id])
        }
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()) {
            if clock.now > deadline { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Маппинг фикса в БД

    @Test func fix_mapsAndLandsInDB_withSegmentBackProjectionTrusted() async throws {
        // Заякоренные часы: trustedAt(elapsedAt) = 1_700_000_000_000 + (elapsedAt − 1000).
        let clock = TrustedClock(elapsedProvider: { 0 }, wallProvider: { 0 }, bootCountProvider: { nil })
        await clock.onServerTime(serverMs: 1_700_000_000_000, anchorElapsed: 1000, wallNow: 1_700_000_000_000, bootNow: nil)

        let rig = try makeRig(clock: clock, wall: 2_000_000, elapsed: 6_000)
        rig.recorder.start(raceId: 7, teamId: 42)
        rig.engine.emit(makeFix(elapsedMs: 5_000, lat: 55.75, lon: 37.61))

        await waitUntil { (try? await self.allPoints(rig.db).count) == 1 }
        let points = try await allPoints(rig.db)
        #expect(points.count == 1)
        let p = try #require(points.first)
        #expect(p.id == "id-1")                 // «id-0» ушёл на сегмент
        #expect(p.segmentId == "id-0")
        #expect(p.lat == 55.75)
        #expect(p.lon == 37.61)
        #expect(p.elapsedRealtimeAt == 5_000)    // нанос / 1e6
        #expect(p.wallMs == 1_999_000)           // 2_000_000 + (5000 − 6000)
        #expect(p.trustedMs == 1_700_000_004_000) // 1_700_000_000_000 + (5000 − 1000)
    }

    // MARK: - Даунсемплинг

    @Test func downsampling_dropsFixesCloserThanInterval() async throws {
        let rig = try makeRig()
        rig.recorder.start(raceId: 7, teamId: 42)
        rig.engine.emit(makeFix(elapsedMs: 1_000))    // сохранён (первый)
        rig.engine.emit(makeFix(elapsedMs: 5_000))    // 4 с < 15 с → отброшен
        rig.engine.emit(makeFix(elapsedMs: 20_000))   // 19 с ≥ 15 с → сохранён

        await waitUntil { (try? await self.allPoints(rig.db).count) == 2 }
        let elapsed = try await allPoints(rig.db).map(\.elapsedRealtimeAt)
        #expect(elapsed == [1_000, 20_000])
    }

    // MARK: - Идемпотентный повторный старт

    @Test func idempotentRepeatStart_keepsSameSegment() async throws {
        let rig = try makeRig()
        rig.recorder.start(raceId: 7, teamId: 42)
        rig.engine.emit(makeFix(elapsedMs: 1_000))
        await waitUntil { (try? await self.allPoints(rig.db).count) == 1 }

        rig.recorder.start(raceId: 7, teamId: 42) // повтор при живой записи — no-op
        rig.engine.emit(makeFix(elapsedMs: 20_000))
        await waitUntil { (try? await self.allPoints(rig.db).count) == 2 }

        let segments = Set(try await allPoints(rig.db).map(\.segmentId))
        #expect(segments == ["id-0"]) // один сегмент на обе точки
    }

    // MARK: - Стоп→старт: новый сегмент

    @Test func stopThenStart_producesTwoDistinctSegments() async throws {
        let rig = try makeRig()
        rig.recorder.start(raceId: 7, teamId: 42)
        rig.engine.emit(makeFix(elapsedMs: 1_000))
        await waitUntil { (try? await self.allPoints(rig.db).count) == 1 }

        rig.recorder.stop()
        #expect(rig.recorder.state == .idle)
        #expect(rig.engine.stopped)

        rig.recorder.start(raceId: 7, teamId: 42) // новый сегмент («id-…» после точки)
        rig.engine.emit(makeFix(elapsedMs: 2_000))
        await waitUntil { (try? await self.allPoints(rig.db).count) == 2 }

        let segments = Set(try await allPoints(rig.db).map(\.segmentId))
        #expect(segments.count == 2)
    }

    // MARK: - Live-upload: первый батч

    @Test func liveUpload_firesOnFirstBatch() async throws {
        let rig = try makeRig()
        // Pending-взятие того же скоупа: live-upload на первом фиксе пиггибечит и его выгрузку.
        try await rig.markStore.upsert(makeMark(id: "m1"))
        rig.recorder.start(raceId: 7, teamId: 42)
        rig.engine.emit(makeFix(elapsedMs: 1_000))

        await waitUntil { (try? await self.point(rig.db, id: "id-1"))?.uploadedCloud == true }
        let p = try await point(rig.db, id: "id-1")
        #expect(p?.uploadedLocal == true)
        #expect(p?.uploadedCloud == true) // первый батч дренится сразу (lastLiveUpload == nil)

        // Пиггибек: взятие тоже дошло тем же пробуждением (handleFix → markRepo.uploadPending).
        await waitUntil { (try? await self.mark(rig.db, id: "m1"))?.uploadedCloud == true }
        let m = try await mark(rig.db, id: "m1")
        #expect(m?.uploadedLocal == true)
        #expect(m?.uploadedCloud == true)
    }

    // MARK: - Live-upload: троттлинг 10 мин

    @Test func liveUpload_throttledWithinInterval_firesAfter() async throws {
        let rig = try makeRig()
        rig.recorder.start(raceId: 7, teamId: 42)

        // Фикс 1 @1 с → сохранён, live-upload сработал (id-1 выгружен).
        rig.engine.emit(makeFix(elapsedMs: 1_000))
        await waitUntil { (try? await self.point(rig.db, id: "id-1"))?.uploadedCloud == true }

        // Фикс 2 @20 с (19 с ≥ 15 с сохранён, но 19 с < 10 мин → live-upload НЕ сработал).
        rig.engine.emit(makeFix(elapsedMs: 20_000))
        await waitUntil { (try? await self.point(rig.db, id: "id-2")) != nil }
        // Детерминированно (без sleep): троттлинг держит ⇔ id-2 не был отправлен ни в один POST /track/.
        // (Выгрузка фикса-1 уже завершилась — ждали её выше, — и на тот момент id-2 не было в БД.)
        #expect(!rig.transport.postedTrackPointIds.contains("id-2"))
        let p2mid = try await point(rig.db, id: "id-2")
        #expect(p2mid?.uploadedCloud == false) // остаётся pending — троттлинг держит

        // Фикс 3 @620 с (>10 мин с последней выгрузки @1 с) → live-upload сработал, id-2 дошёл.
        rig.engine.emit(makeFix(elapsedMs: 620_000))
        await waitUntil { (try? await self.point(rig.db, id: "id-2"))?.uploadedCloud == true }
        let p2end = try await point(rig.db, id: "id-2")
        #expect(p2end?.uploadedCloud == true)
    }

    // MARK: - Стоп: lossless-дозапись пришедшего фикса

    @Test func stop_persistsArrivedFix_lossless() async throws {
        let rig = try makeRig()
        rig.recorder.start(raceId: 7, teamId: 42)
        rig.engine.emit(makeFix(elapsedMs: 1_000))
        rig.recorder.stop() // стоп сразу за эмиссией — вставка (захватила стор) переживает стоп

        await waitUntil { (try? await self.allPoints(rig.db).count) == 1 }
        #expect(try await allPoints(rig.db).count == 1)
    }

    // MARK: - Стоп: opportunistic-выгрузка pending

    @Test func stop_opportunisticallyUploadsPending() async throws {
        let rig = try makeRig()
        rig.recorder.start(raceId: 7, teamId: 42) // фиксирует скоуп (7,42) для стоп-выгрузки
        // Предвставим pending-точку напрямую (без фикса → без live-upload).
        try await rig.trackStore.insertAll([
            TrackPoint(
                id: "pre", raceId: 7, teamId: 42, lat: 55, lon: 37, accuracy: 5,
                gpsTimeMs: 1, elapsedRealtimeAt: 1, wallMs: 1, segmentId: "seg", uploadedLocal: false, uploadedCloud: false
            )
        ])

        // И pending-взятие того же скоупа — стоп-дренаж пиггибечит и его (markRepo.uploadPending).
        try await rig.markStore.upsert(makeMark(id: "m1"))

        rig.recorder.stop() // opportunistic uploadPending(7,42) дренит «pre» + «m1»

        await waitUntil { (try? await self.point(rig.db, id: "pre"))?.uploadedCloud == true }
        let p = try await point(rig.db, id: "pre")
        #expect(p?.uploadedLocal == true)
        #expect(p?.uploadedCloud == true)

        await waitUntil { (try? await self.mark(rig.db, id: "m1"))?.uploadedCloud == true }
        let m = try await mark(rig.db, id: "m1")
        #expect(m?.uploadedLocal == true)
        #expect(m?.uploadedCloud == true)
    }

    // MARK: - Стрим движка иссяк сам (не через stop()) → откат в idle

    @Test func streamEndsWithoutStop_returnsToIdle() async throws {
        let rig = try makeRig()
        rig.recorder.start(raceId: 7, teamId: 42)
        rig.engine.emit(makeFix(elapsedMs: 1_000))
        await waitUntil { (try? await self.allPoints(rig.db).count) == 1 }
        #expect(rig.recorder.state == .recording(teamId: 42))

        // Движок сам закрывает поток (отзыв геодоступа / ошибка CoreLocation) — БЕЗ вызова stop().
        rig.engine.finish()

        await waitUntil { rig.recorder.state == .idle }
        #expect(rig.recorder.state == .idle) // иначе TrackCard навсегда «Идёт запись»
        #expect(rig.recorder.pointCount == 0)
        // (Рекордер при этом инвалидирует движок — освобождает фоновую сессию; отдельно не проверяем.)
    }

    // MARK: - Сегментная изоляция: поздний буферизованный фикс СТАРОЙ сессии

    @Test func lateBufferedFix_landsOnOwnSegment_notNewSession() async throws {
        let rig = try makeRig()
        // Синхронно (без await между шагами): фикс буферизуется в стриме СЕССИИ A, затем стоп→старт
        // подменяют текущую сессию на B ДО того, как цикл A успел обработать буферизованный фикс.
        rig.recorder.start(raceId: 7, teamId: 42)        // сессия A, segmentId «id-0»
        rig.engine.emit(makeFix(elapsedMs: 1_000))        // буферизован в стриме A (цикл A ещё не крутился)
        rig.recorder.stop()                               // self.session = nil; стрим A завершается
        rig.recorder.start(raceId: 7, teamId: 42)         // сессия B, segmentId «id-1»
        rig.engine.emit(makeFix(elapsedMs: 2_000))        // в стрим B → сессия B

        await waitUntil { (try? await self.allPoints(rig.db).count) == 2 }
        // Точки идентифицируем по elapsedRealtimeAt (порядок минтинга point-id между циклами не детерминирован).
        // Фикс A дренится ПОСЛЕ подмены self.session на B, но цикл держит захваченную сессию A — значит его
        // точка на сегменте A («id-0»), а не B («id-1»): сегментная изоляция ссылочного `Session`.
        let points = try await allPoints(rig.db)
        let pA = points.first { $0.elapsedRealtimeAt == 1_000 } // фикс A (сессия A)
        let pB = points.first { $0.elapsedRealtimeAt == 2_000 } // фикс B (сессия B)
        #expect(pA?.segmentId == "id-0")
        #expect(pB?.segmentId == "id-1")
        #expect(pA?.segmentId != pB?.segmentId)
    }

    // MARK: - Прогрев разрешения при тапе «Начать запись»

    @Test func start_primesLocationAuthorization() async throws {
        final class Flag: @unchecked Sendable { var primed = false }
        let flag = Flag()
        let rig = try makeRig(onRequestAuth: { flag.primed = true })

        rig.recorder.start(raceId: 7, teamId: 42)

        #expect(flag.primed) // тап прогрел разрешение (иначе первый старт до скан-оверлея не записывает)
        #expect(rig.recorder.state == .recording(teamId: 42))
    }

    // MARK: - Отказ геодоступа

    @Test func geoDenied_doesNotStart_firesCallback() async throws {
        final class Flag: @unchecked Sendable { var fired = false; var primed = false }
        let flag = Flag()
        let rig = try makeRig(
            hasAccess: false,
            onGeoDenied: { flag.fired = true },
            onRequestAuth: { flag.primed = true }
        )

        rig.recorder.start(raceId: 7, teamId: 42)

        #expect(flag.primed)                       // прогрев случился до TOCTOU-проверки
        #expect(rig.recorder.state == .idle)       // подлинный отказ (не `.notDetermined`) не стартует
        #expect(flag.fired)                        // …и всё равно тостит
        rig.engine.emit(makeFix(elapsedMs: 1_000)) // движок не запущен — фикс никуда не идёт
        try? await Task.sleep(for: .milliseconds(50))
        #expect(try await allPoints(rig.db).isEmpty)
    }

    // MARK: - Смена команды в AppModel останавливает запись; повтор той же — нет

    @Test func teamChange_stopsRecording_butRepeatSameTeamDoesNot() async throws {
        let transport = RoutingTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.teamStore.insertTeams([
            Team(id: 5, raceId: 7, teamname: "A", startNumber: "1", categoryId: nil, ucount: 1, paidPeople: 1,
                 startTime: 0, finishTime: 0, members: [TeamMemberItem(name: "Аня", numberInTeam: 1)]),
            Team(id: 6, raceId: 7, teamname: "B", startNumber: "2", categoryId: nil, ucount: 1, paidPeople: 1,
                 startTime: 0, finishTime: 0, members: [TeamMemberItem(name: "Боб", numberInTeam: 1)]),
        ])
        // Pending-точка трека команды 5: смена команды (team-change flush → trackRepo.uploadAllPending)
        // должна её дослать.
        try await env.trackStore.insertAll([
            TrackPoint(
                id: "tp5", raceId: 7, teamId: 5, lat: 55, lon: 37, accuracy: 5,
                gpsTimeMs: 1, elapsedRealtimeAt: 1, wallMs: 1, segmentId: "seg", uploadedLocal: false, uploadedCloud: false
            )
        ])

        let model = AppModel(env: env)
        await model.start()

        await model.selectTeam(raceId: 7, teamId: 5)
        await waitUntil { model.selectedTeamId == 5 }

        // Триггер team-change flush отработал: точка трека выгружена в облако.
        func trackPoint(_ id: String) async throws -> TrackPoint? {
            try await env.database.writer.read { db in
                try TrackPoint.fetchOne(db, sql: "SELECT * FROM track_points WHERE id = ?", arguments: [id])
            }
        }
        await waitUntil { (try? await trackPoint("tp5"))?.uploadedCloud == true }
        #expect(try await trackPoint("tp5")?.uploadedCloud == true)

        // Запускаем запись команды 5.
        model.trackRecorder.start(raceId: 7, teamId: 5)
        #expect(model.trackRecorder.state == .recording(teamId: 5))

        // Повторная эмиссия ТОЙ ЖЕ команды (resync) — запись не трогаем.
        await model.selectTeam(raceId: 7, teamId: 5)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(model.trackRecorder.state == .recording(teamId: 5))

        // Подлинная смена команды → запись остановлена.
        await model.selectTeam(raceId: 7, teamId: 6)
        await waitUntil { model.trackRecorder.state == .idle }
        #expect(model.trackRecorder.state == .idle)
    }
}
