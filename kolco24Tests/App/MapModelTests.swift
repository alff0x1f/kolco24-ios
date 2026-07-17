//
//  MapModelTests.swift
//  kolco24Tests
//
//  Тесты `MapModel` — Android-зеркала нет (вкладка iOS-only), пишутся с нуля поверх РЕАЛЬНЫХ store'ов
//  над `AppDatabase.makeInMemory()` (конвенция этапа 4) + инжектированных фейковых map-замыканий графа
//  (наличие файла / путь / скачивание) — без сети/диска/MapKit. Проверяем машину состояний доступности
//  (`noMapForRace`/`notDownloaded`/`downloading`/`ready`/`failed`), скачивание (успех/ошибка/отмена),
//  `refreshAvailability` (подхват удаления файла), производные (фильтр/сортировка трека, пин только с
//  GPS-фиксом, фолбэк цены/номера) и stale-guard при смене команды.
//
//  observation эмитит асинхронно — состояние ждём поллингом с таймаутом.
//

import Foundation
import Testing
@testable import kolco24

/// Потокобезопасные фейки map-замыканий графа: множество «скачанных» гонок + запись тостов. Замыкания
/// `@Sendable`, поэтому бокс под `NSLock`.
private final class MapFakes: @unchecked Sendable {
    private let lock = NSLock()
    private var files: Set<Int> = []
    private(set) var toasts: [String] = []

    func exists(_ raceId: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return files.contains(raceId) }
    func setFile(_ raceId: Int) { lock.lock(); defer { lock.unlock() }; files.insert(raceId) }
    func removeFile(_ raceId: Int) { lock.lock(); defer { lock.unlock() }; files.remove(raceId) }
    func recordToast(_ m: String) { lock.lock(); defer { lock.unlock() }; toasts.append(m) }
    func path(_ raceId: Int) -> String { "/tmp/maps/\(raceId).mbtiles" }
}

private struct MapDownloadError: Error {}

@MainActor
struct MapModelTests {

    // MARK: - Фикстуры

    private func race(_ id: Int, mapUrl: String?) -> Race {
        Race(id: id, name: "R\(id)", slug: "r\(id)", date: "2026-02-01", place: "P",
             regStatus: "open", mapUrl: mapUrl)
    }

    private func openCP(id: Int, race: Int, number: Int, cost: Int) -> Checkpoint {
        Checkpoint(id: id, raceId: race, number: number, cost: cost, type: "cp",
                   description: "КП \(number)", locked: false)
    }

    private func trackPoint(
        id: String, race: Int, team: Int, lat: Double, lon: Double,
        accuracy: Float = 10, wallMs: Int64
    ) -> TrackPoint {
        TrackPoint(id: id, raceId: race, teamId: team, lat: lat, lon: lon, accuracy: accuracy,
                   gpsTimeMs: wallMs, elapsedRealtimeAt: wallMs, wallMs: wallMs, segmentId: "seg")
    }

    private func mark(
        id: String, race: Int, team: Int, cp: Int, number: Int, cost: Int,
        takenAt: Int64 = 0, lat: Double? = nil, lon: Double? = nil
    ) -> Mark {
        Mark(id: id, raceId: race, teamId: team, checkpointId: cp, checkpointNumber: number,
             cost: cost, method: "nfc", cpUid: "UID\(cp)", cpCode: "K24", present: [1],
             expectedCount: 1, complete: true, takenAt: takenAt, updatedAt: takenAt,
             locLat: lat, locLon: lon)
    }

    /// Граф с инжектированными map-замыканиями поверх [fakes] и заданным download-поведением.
    private func makeEnv(
        _ fakes: MapFakes,
        download: @escaping @Sendable (URL, Int, @escaping @Sendable (Double) -> Void) async throws -> Void = { _, _, _ in }
    ) throws -> AppEnvironment {
        try AppEnvironment.inMemory(
            transport: FakeTransport().handle,
            mapFileExists: { fakes.exists($0) },
            mapFilePath: { fakes.path($0) },
            mapFileSize: { _ in nil },
            deleteMapFile: { _ in },
            downloadMapFile: download
        )
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Доступность: noMapForRace

    @Test func noMapForRaceWhenMapUrlNil() async throws {
        let fakes = MapFakes()
        let env = try makeEnv(fakes)
        // Гонка есть, но mapUrl == nil, а файл даже присутствует — nil короткозамыкается на noMapForRace.
        try await env.raceStore.insertAll([race(7, mapUrl: nil)])
        fakes.setFile(7)
        try await env.checkpointStore.insertCheckpoints([openCP(id: 1, race: 7, number: 1, cost: 5)])

        let model = MapModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        // Ждём отработки наблюдений/availabilityTask (getById быстр), затем ассертим отсутствие карты.
        await waitUntil { model.checkpoints.count == 1 }
        try? await Task.sleep(for: .milliseconds(60))
        #expect(model.availability == .noMapForRace)
    }

    // MARK: - Доступность: notDownloaded → downloading → ready

    @Test func notDownloadedThenDownloadThenReady() async throws {
        let fakes = MapFakes()
        let env = try makeEnv(fakes) { _, raceId, onProgress in
            onProgress(0.5)
            fakes.setFile(raceId)   // файл появился — последующий refresh даст ready
        }
        try await env.raceStore.insertAll([race(7, mapUrl: "https://cdn.test/7.mbtiles")])

        let model = MapModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.availability == .notDownloaded }
        #expect(model.availability == .notDownloaded)

        model.downloadMap()
        // Переход в downloading выставляется синхронно (до старта Task).
        #expect(model.availability == .downloading(progress: 0))

        await waitUntil { model.availability == .ready(path: fakes.path(7)) }
        #expect(model.availability == .ready(path: "/tmp/maps/7.mbtiles"))
    }

    // MARK: - Ошибка скачивания → failed → (refresh) notDownloaded + тост

    @Test func downloadErrorFailsThenRefreshResetsAndToasts() async throws {
        let fakes = MapFakes()
        let env = try makeEnv(fakes) { _, _, _ in throw MapDownloadError() }
        try await env.raceStore.insertAll([race(7, mapUrl: "https://cdn.test/7.mbtiles")])

        let model = MapModel(env: env, onToast: { fakes.recordToast($0) })
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.availability == .notDownloaded }

        model.downloadMap()
        await waitUntil { if case .failed = model.availability { return true }; return false }
        #expect(model.availability == .failed(message: "Не удалось скачать карту гонки"))
        #expect(fakes.toasts == ["Не удалось скачать карту гонки"])

        // Файла нет → refresh возвращает CTA в notDownloaded (повтор доступен).
        model.refreshAvailability()
        await waitUntil { model.availability == .notDownloaded }
        #expect(model.availability == .notDownloaded)
    }

    // MARK: - Отмена скачивания

    @Test func cancelDownloadReturnsToNotDownloaded() async throws {
        let fakes = MapFakes()
        let env = try makeEnv(fakes) { _, _, _ in
            try await Task.sleep(for: .seconds(10))  // «долгое» скачивание — отменяем на лету
        }
        try await env.raceStore.insertAll([race(7, mapUrl: "https://cdn.test/7.mbtiles")])

        let model = MapModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.availability == .notDownloaded }

        model.downloadMap()
        #expect(model.availability == .downloading(progress: 0))
        model.cancelDownload()
        #expect(model.availability == .notDownloaded)
    }

    // MARK: - ready сразу при существующем файле

    @Test func readyImmediatelyWhenFileExists() async throws {
        let fakes = MapFakes()
        let env = try makeEnv(fakes)
        try await env.raceStore.insertAll([race(7, mapUrl: "https://cdn.test/7.mbtiles")])
        fakes.setFile(7)

        let model = MapModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.availability == .ready(path: fakes.path(7)) }
        #expect(model.availability == .ready(path: "/tmp/maps/7.mbtiles"))
    }

    // MARK: - refreshAvailability после удаления файла → ready → notDownloaded

    @Test func refreshRevertsReadyToNotDownloadedAfterFileRemoved() async throws {
        let fakes = MapFakes()
        let env = try makeEnv(fakes)
        try await env.raceStore.insertAll([race(7, mapUrl: "https://cdn.test/7.mbtiles")])
        fakes.setFile(7)

        let model = MapModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.availability == .ready(path: fakes.path(7)) }

        // Пользователь удалил карту в настройках — файл-как-флаг не наблюдаем, ловим на refresh.
        fakes.removeFile(7)
        model.refreshAvailability()
        await waitUntil { model.availability == .notDownloaded }
        #expect(model.availability == .notDownloaded)
    }

    // MARK: - Производные: фильтр/сортировка трека, пины

    @Test func derivedTrackPathAndPins() async throws {
        let fakes = MapFakes()
        let env = try makeEnv(fakes)
        try await env.checkpointStore.insertCheckpoints([
            openCP(id: 1, race: 7, number: 5, cost: 9),   // живая цена 9 (снимок взятия — 2)
        ])
        // Точки: разный порядок времени + одна грубая (accuracy 99 > 50) — отбрасывается фильтром.
        try await env.trackStore.insertAll([
            trackPoint(id: "b", race: 7, team: 42, lat: 2, lon: 2, wallMs: 2_000),
            trackPoint(id: "a", race: 7, team: 42, lat: 1, lon: 1, wallMs: 1_000),
            trackPoint(id: "bad", race: 7, team: 42, lat: 9, lon: 9, accuracy: 99, wallMs: 500),
        ])
        // Взятия: с фиксом (пин, живая цена), с фиксом но КП не в легенде (фолбэк цены/номера),
        // без фикса (пина нет).
        try await env.markStore.upsert(mark(id: "m1", race: 7, team: 42, cp: 1, number: 5, cost: 2,
                                             takenAt: 100, lat: 10.5, lon: 20.5))
        try await env.markStore.upsert(mark(id: "m2", race: 7, team: 42, cp: 8, number: 8, cost: 4,
                                             takenAt: 200, lat: 30.0, lon: 40.0))
        try await env.markStore.upsert(mark(id: "m3", race: 7, team: 42, cp: 1, number: 5, cost: 2,
                                             takenAt: 300, lat: nil, lon: nil))

        let model = MapModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.checkpoints.count == 1 && model.marks.count == 3 && model.trackPoints.count == 3 }

        // Трек: грубая точка отброшена, порядок по времени (a → b).
        let path = model.trackPath
        #expect(path.count == 2)
        #expect(path.map(\.lat) == [1, 2])

        // Пины: два (m1, m2), m3 без фикса не даёт пина.
        let pins = model.pins
        #expect(pins.count == 2)
        let p1 = try #require(pins.first { $0.lat == 10.5 })
        #expect(p1.number == 5)
        #expect(p1.cost == 9)          // живая цена КП1, не снимок 2
        #expect(p1.timeMs == 100)
        let p2 = try #require(pins.first { $0.lat == 30.0 })
        #expect(p2.number == 8)        // фолбэк на снимок (КП8 нет в легенде)
        #expect(p2.cost == 4)          // фолбэк на снимок цены
    }

    // MARK: - stale-guard при смене команды

    @Test func rebindClearsPreviousTeamDataSynchronously() async throws {
        let fakes = MapFakes()
        let env = try makeEnv(fakes)
        try await env.checkpointStore.insertCheckpoints([openCP(id: 1, race: 7, number: 5, cost: 9)])
        try await env.trackStore.insertAll([trackPoint(id: "a", race: 7, team: 42, lat: 1, lon: 1, wallMs: 1_000)])
        try await env.markStore.upsert(mark(id: "m1", race: 7, team: 42, cp: 1, number: 5, cost: 9,
                                             lat: 10.5, lon: 20.5))

        let model = MapModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { !model.trackPoints.isEmpty && !model.marks.isEmpty && !model.checkpoints.isEmpty }

        // Смена команды/гонки очищает строки прежней синхронно (до первой эмиссии новой).
        model.rebind(teamId: 99, raceId: 8)
        #expect(model.trackPoints.isEmpty)
        #expect(model.marks.isEmpty)
        #expect(model.checkpoints.isEmpty)
        #expect(model.trackPath.isEmpty)
        #expect(model.pins.isEmpty)
        #expect(model.availability == .noMapForRace)
    }
}
