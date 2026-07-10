//
//  PhotoModelTests.swift
//  kolco24Tests
//
//  Тесты `PhotoModel` — Android-зеркала нет (логика размазана по `MainActivity`), пишутся с нуля
//  поверх РЕАЛЬНЫХ store'ов над `AppDatabase.makeInMemory()` + фейков только на границах диска/времени/
//  локации (`writeFrame`/`deleteFrame`/`sampleNow`/`CurrentLocationProvider`). Проверяем поведенческую
//  спецификацию Task 6: attach-ветка, picker-ветка, changeCheckpoint, orphan-guard, discard,
//  firstSample-на-первом-кадре, startup-sweep.
//

import Foundation
import Testing
@testable import kolco24

@MainActor
struct PhotoModelTests {

    // MARK: - Фикстуры

    private let race = 7
    private let team = 42

    private func makeEnv() throws -> AppEnvironment {
        try AppEnvironment.inMemory(transport: FakeTransport().handle)
    }

    /// Записыватель кадров: детерминированный относительный путь + журнал вызовов (thread-safe — зовётся
    /// вне main из `Task.detached`).
    final class FrameWriter: @unchecked Sendable {
        private let lock = NSLock()
        private var counter = 0
        private(set) var writes: [String] = []
        func write(_ markId: String, _ data: Data) -> String? {
            lock.lock(); defer { lock.unlock() }
            counter += 1
            let path = "marks/\(markId)/frame-\(counter).jpg"
            writes.append(path)
            return path
        }
    }

    /// Удалятель кадров: журнал путей (thread-safe).
    final class FrameDeleter: @unchecked Sendable {
        private let lock = NSLock()
        private var _deleted: [String] = []
        func delete(_ path: String) {
            lock.lock(); defer { lock.unlock() }
            _deleted.append(path)
        }
        var deleted: [String] { lock.lock(); defer { lock.unlock() }; return _deleted }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _deleted.count }
    }

    /// One-shot GPS-фейк (актор — читается без гонок из detached-Task attach'а).
    actor RecordingLocationProvider: CurrentLocationProvider {
        let fix: RawFix?
        private(set) var callCount = 0
        init(fix: RawFix?) { self.fix = fix }
        func current(timeoutMs: Int64) async -> RawFix? { callCount += 1; return fix }
    }

    /// Счётчик семплов времени: каждый вызов даёт wallMs = base * n (для проверки firstSample-на-первом).
    actor SampleCounter {
        private var n = 0
        let base: Int64
        init(base: Int64 = 1000) { self.base = base }
        func next() -> TimeSample {
            n += 1
            let w = base * Int64(n)
            return TimeSample(wallMs: w, elapsedMs: w, trustedMs: nil, bootCount: nil)
        }
        var callCount: Int { n }
    }

    /// Детерминированный генератор id standalone-марки.
    final class IdGen: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> String { lock.lock(); defer { lock.unlock() }; n += 1; return "photo-\(n)" }
    }

    private func validFix() -> RawFix {
        RawFix(lat: 55.75, lon: 37.61, accuracy: 5, altitude: 150, verticalAccuracyMeters: 3,
               gpsTimeMs: 1_700_000_000_000, elapsedRealtimeNanos: 500_000_000)
    }

    private func fixedSample(_ wall: Int64 = 5000) -> @Sendable () async -> TimeSample {
        { TimeSample(wallMs: wall, elapsedMs: wall, trustedMs: nil, bootCount: nil) }
    }

    private func insertCp(_ env: AppEnvironment, id: Int, number: Int, cost: Int) async throws {
        try await env.checkpointStore.insertCheckpoints([
            Checkpoint(id: id, raceId: race, number: number, cost: cost, type: "cp",
                       description: "КП \(number)", locked: false)
        ])
    }

    private func completeNfcMark(id: String, cpId: Int, number: Int, cost: Int, wall: Int64) -> Mark {
        Mark(id: id, raceId: race, teamId: team, checkpointId: cpId, checkpointNumber: number,
             cost: cost, method: "nfc", cpUid: "CP", cpCode: "", present: [1], expectedCount: 1,
             complete: true, takenAt: wall, updatedAt: wall,
             photosUploadedLocal: true, photosUploadedCloud: true, trustedTakenAt: wall)
    }

    private func makeModel(
        env: AppEnvironment,
        raceId: Int? = 7,
        teamId: Int? = 42,
        rosterSize: Int = 1,
        location: any CurrentLocationProvider = RecordingLocationProvider(fix: nil),
        sampleNow: @escaping @Sendable () async -> TimeSample,
        writer: FrameWriter = FrameWriter(),
        deleter: FrameDeleter = FrameDeleter(),
        ids: IdGen = IdGen()
    ) -> PhotoModel {
        PhotoModel(
            raceId: raceId, teamId: teamId, rosterSize: rosterSize,
            checkpointStore: env.checkpointStore, markStore: env.markStore,
            locationProvider: location, sampleNow: sampleNow,
            writeFrame: { m, d in writer.write(m, d) },
            deleteFrame: { p in deleter.delete(p) },
            newMarkId: { ids.next() }
        )
    }

    private func fetch(_ env: AppEnvironment, _ id: String) async -> Mark? {
        (try? await env.markStore.getById(id)) ?? nil
    }

    private func poll(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()) {
            if clock.now > deadline { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - attach-ветка (свежее взятие в окне)

    @Test func attachBranchAppendsFramesAndResetsPhotoFlags() async throws {
        let env = try makeEnv()
        try await env.markStore.upsert(
            completeNfcMark(id: "nfc-1", cpId: 100, number: 32, cost: 4, wall: 5000)
        )
        let model = makeModel(env: env, sampleNow: fixedSample(5000))
        await model.start()
        #expect(model.route == .camera(attach: true))
        #expect(model.cpNumber == 32)

        await model.addFrame(jpegData: Data([0xFF, 0xD8]))
        #expect(model.frames.count == 1)
        model.commit()
        #expect(model.closeRequested)

        await poll { (await self.fetch(env, "nfc-1"))?.photosUploadedLocal == false }
        let m = try #require(await fetch(env, "nfc-1"))
        #expect(m.photosUploadedLocal == false)
        #expect(m.photosUploadedCloud == false)
        #expect(PhotoPaths.decode(m.photoPath).count == 1)
        // attach не создаёт новую строку — прикрепление к существующей.
        #expect(try await env.markStore.allIds() == ["nfc-1"])
    }

    // MARK: - picker-ветка (новая standalone фото-марка)

    @Test func pickerBranchCreatesPhotoMarkWithRosterAndGps() async throws {
        let env = try makeEnv()
        try await insertCp(env, id: 100, number: 32, cost: 4)
        let loc = RecordingLocationProvider(fix: validFix())
        let model = makeModel(env: env, rosterSize: 3, location: loc, sampleNow: fixedSample(6000))
        await model.start()
        #expect(model.route == .picker)
        await poll { !model.legend.isEmpty }

        model.submit(number: 32)
        #expect(model.route == .camera(attach: false))
        #expect(model.cpNumber == 32)
        #expect(model.pickerError == nil)

        await model.addFrame(jpegData: Data([0xFF, 0xD8]))
        model.commit()

        await poll { (await self.fetch(env, "photo-1")) != nil }
        let m = try #require(await fetch(env, "photo-1"))
        #expect(m.method == "photo")
        #expect(m.complete == true)
        #expect(m.present == [])
        #expect(m.expectedCount == 3)          // размер ростера
        #expect(m.cost == 4)
        #expect(m.checkpointNumber == 32)
        #expect(m.takenAt == 6000)
        #expect(PhotoPaths.decode(m.photoPath).count == 1)

        // GPS-фикс догнал (one-shot attachLocation после upsert).
        await poll { (await self.fetch(env, "photo-1"))?.locLat != nil }
        let withGps = try #require(await fetch(env, "photo-1"))
        #expect(withGps.locLat == 55.75)
    }

    // MARK: - changeCheckpoint: attach → пикер → марка с новым UUID

    @Test func changeCheckpointCreatesStandaloneWithNewUuid() async throws {
        let env = try makeEnv()
        try await insertCp(env, id: 100, number: 32, cost: 4)
        try await env.markStore.upsert(
            completeNfcMark(id: "nfc-1", cpId: 100, number: 32, cost: 4, wall: 7000)
        )
        let model = makeModel(env: env, sampleNow: fixedSample(7000))
        await model.start()
        #expect(model.route == .camera(attach: true))
        await model.addFrame(jpegData: Data([0xFF]))    // пишется под nfc-1 (осиротеет)

        model.changeCheckpoint()
        #expect(model.route == .picker)
        #expect(model.frames.isEmpty)
        await poll { !model.legend.isEmpty }

        model.submit(number: 32)
        #expect(model.route == .camera(attach: false))
        await model.addFrame(jpegData: Data([0xFF]))    // пишется под photo-1
        model.commit()

        await poll { (await self.fetch(env, "photo-1")) != nil }
        let m = try #require(await fetch(env, "photo-1"))
        #expect(m.method == "photo")
        #expect(m.checkpointNumber == 32)
        // Прежнее NFC-взятие не получило пост-change кадр (attachPhotos не звался для nfc-1).
        let nfc = try #require(await fetch(env, "nfc-1"))
        #expect(nfc.photoPath == nil)
    }

    // MARK: - невалидный номер → ошибка, марки нет

    @Test func invalidNumberSetsErrorNoMark() async throws {
        let env = try makeEnv()
        try await insertCp(env, id: 100, number: 32, cost: 4)
        let model = makeModel(env: env, sampleNow: fixedSample())
        await model.start()
        await poll { !model.legend.isEmpty }

        model.submit(number: 99)
        #expect(model.pickerError != nil)
        #expect(model.route == .picker)
        #expect(try await env.markStore.allIds().isEmpty)
    }

    // MARK: - orphan-guard коммита (nil team) — марки нет, без краша

    @Test func orphanGuardNilTeamNoMark() async throws {
        let env = try makeEnv()
        try await insertCp(env, id: 100, number: 32, cost: 4)
        // raceId есть (легенда наблюдается), teamId nil — standalone-коммит осиротит кадры.
        let model = makeModel(env: env, teamId: nil, rosterSize: 0, sampleNow: fixedSample())
        await model.start()
        #expect(model.route == .picker)
        await poll { !model.legend.isEmpty }

        model.submit(number: 32)
        #expect(model.route == .camera(attach: false))
        await model.addFrame(jpegData: Data([0xFF]))
        model.commit()
        #expect(model.closeRequested)

        // Дать fire-and-forget Task коммита отработать; марки не должно появиться.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(try await env.markStore.allIds().isEmpty)
    }

    // MARK: - discard удаляет только кадры этой сессии

    @Test func discardDeletesOnlyOwnFrames() async throws {
        let env = try makeEnv()
        try await insertCp(env, id: 100, number: 32, cost: 4)
        let deleter = FrameDeleter()
        let model = makeModel(env: env, sampleNow: fixedSample(), deleter: deleter)
        await model.start()
        await poll { !model.legend.isEmpty }
        model.submit(number: 32)
        await model.addFrame(jpegData: Data([0x01]))
        await model.addFrame(jpegData: Data([0x02]))
        let paths = model.frames
        #expect(paths.count == 2)

        model.discard()
        #expect(model.frames.isEmpty)
        await poll { deleter.count == 2 }
        #expect(Set(deleter.deleted) == Set(paths))
    }

    // MARK: - firstSample только с первого кадра

    @Test func firstSampleOnlyOnFirstFrame() async throws {
        let env = try makeEnv()
        try await insertCp(env, id: 100, number: 32, cost: 4)
        let counter = SampleCounter(base: 1000)
        let model = makeModel(
            env: env, location: RecordingLocationProvider(fix: nil),
            sampleNow: { await counter.next() }
        )
        // start() → 1-й вызов (1000, для decidePhotoTarget).
        await model.start()
        await poll { !model.legend.isEmpty }
        model.submit(number: 32)

        await model.addFrame(jpegData: Data([0x01]))   // 2-й вызов (2000) → firstSample
        await model.addFrame(jpegData: Data([0x02]))   // семпл НЕ берётся
        model.commit()

        await poll { (await self.fetch(env, "photo-1")) != nil }
        let m = try #require(await fetch(env, "photo-1"))
        #expect(m.takenAt == 2000)                     // wallMs первого кадра, не второго
        #expect(await counter.callCount == 2)          // start + первый кадр
    }

    // MARK: - startup-sweep: сносит сироту, щадит живой каталог

    @Test func startupSweepRemovesOrphanSparesLive() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("photo-sweep-\(UUID().uuidString)")
        let storage = PhotoStorage(rootURL: tmp)
        let liveDir = storage.marksRoot.appendingPathComponent("live-1", isDirectory: true)
        let orphanDir = storage.marksRoot.appendingPathComponent("orphan-9", isDirectory: true)
        try fm.createDirectory(at: liveDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let fake = FakeTransport()
        // launchStartupRefresh дёрнет один conditional GET (нет гонок → nearestRaceId nil, дальше не идёт).
        for _ in 0..<4 { fake.enqueue(statusCode: 304) }
        let env = try AppEnvironment.inMemory(
            transport: fake.handle,
            sweepOrphanPhotoDirs: { ids in storage.sweepOrphanDirs(liveMarkIds: ids) }
        )
        // Полностью выгруженная строка — не тянет upload-дренаж на сеть; её id — «живой» для sweep.
        try await env.markStore.upsert(
            Mark(id: "live-1", raceId: race, teamId: team, checkpointId: 1, checkpointNumber: 1,
                 cost: 1, method: "nfc", cpUid: "", cpCode: "", present: [], expectedCount: 1,
                 complete: true, takenAt: 0, updatedAt: 0, uploadedLocal: true, uploadedCloud: true,
                 photosUploadedLocal: true, photosUploadedCloud: true)
        )
        let appModel = AppModel(env: env)
        await appModel.start()

        await poll { !fm.fileExists(atPath: orphanDir.path) }
        #expect(!fm.fileExists(atPath: orphanDir.path))   // сирота снесена
        #expect(fm.fileExists(atPath: liveDir.path))      // живой каталог сохранён
    }
}
