//
//  RaceRepositoryTests.swift
//  kolco24Tests
//
//  Зеркало `data/RaceRepositoryTest.kt` (12 кейсов) поверх РЕАЛЬНЫХ store'ов над
//  `AppDatabase.makeInMemory()` (конвенция этапа 2 — без фейков) + `FakeTransport` (замена
//  `MockWebServer`). Отдельный cloud/local `FakeTransport` играет роль двух `MockWebServer`'ов —
//  по числу перехваченных запросов проверяем, какой сервер дёрнули.
//
//  Порядок «данные → потом ETag» (`success_writesDataBeforeEtag`) проверяется трассировкой SQL
//  реальной БД (`Database.trace`) — Swift-аналог callLog'а из фейкового DAO в Kotlin: последователь-
//  ность реально исполненных операторов должна быть deleteEtag → replaceAll → upsertEtag.
//

import Foundation
import GRDB
import Testing
@testable import kolco24

struct RaceRepositoryTests {

    private let cloudOrigin = "https://cloud.test"
    private let localOrigin = "http://local.test"

    // MARK: - Фикстуры

    private func racesJson(id: Int, name: String) -> String {
        """
        {
          "races": [
            {
              "id": \(id),
              "name": "\(name)",
              "slug": "race-\(id)",
              "date": "2026-06-20",
              "date_end": null,
              "place": "Сосновый бор",
              "reg_status": "open",
              "is_legend_visible": true
            }
          ]
        }
        """
    }

    private func makeApiClient(baseURL: String, transport: FakeTransport) -> ApiClient {
        ApiClient(
            baseURL: baseURL,
            keyId: "ios-v1",
            secret: "test-secret-123",
            installId: "install-abc",
            appVersion: "2.0.1",
            nowSeconds: { 1_718_200_000 },
            elapsedNowMs: { 0 },
            onServerTime: nil,
            tokenProvider: { nil },
            transport: transport.handle
        )
    }

    private struct Harness {
        let repo: RaceRepository
        let dbWriter: any DatabaseWriter
        let raceStore: RaceStore
        let syncMetaStore: SyncMetaStore
        let cloudTransport: FakeTransport
        let localTransport: FakeTransport
    }

    private func makeHarness(dbWriter: any DatabaseWriter) -> Harness {
        let cloudTransport = FakeTransport()
        let localTransport = FakeTransport()
        let raceStore = RaceStore(dbWriter)
        let syncMetaStore = SyncMetaStore(dbWriter)
        let repo = RaceRepository(
            apiClient: makeApiClient(baseURL: cloudOrigin, transport: cloudTransport),
            raceStore: raceStore,
            syncMetaStore: syncMetaStore,
            origin: cloudOrigin,
            localApiClient: makeApiClient(baseURL: localOrigin, transport: localTransport),
            localOrigin: localOrigin
        )
        return Harness(
            repo: repo,
            dbWriter: dbWriter,
            raceStore: raceStore,
            syncMetaStore: syncMetaStore,
            cloudTransport: cloudTransport,
            localTransport: localTransport
        )
    }

    private func makeHarness() throws -> Harness {
        makeHarness(dbWriter: try AppDatabase.makeInMemory().writer)
    }

    /// Текущие строки таблицы `races` (тот же порядок, что у `observeRaces`).
    private func storedRaces(_ dbWriter: any DatabaseWriter) async throws -> [Race] {
        try await dbWriter.read { db in
            try Race.fetchAll(db, sql: "SELECT * FROM races ORDER BY date DESC, id DESC")
        }
    }

    private func seedRace(_ store: RaceStore, id: Int, name: String) async throws {
        try await store.replaceAll([
            Race(id: id, name: name, slug: "race-\(id)", date: "2026-06-20",
                 dateEnd: nil, place: "Сосновый бор", regStatus: "open"),
        ])
    }

    // MARK: - Зеркало RaceRepositoryTest.kt

    @Test func success_replacesTableAndStoresEtag() async throws {
        let h = try makeHarness()
        try await seedRace(h.raceStore, id: 99, name: "Stale race")
        h.cloudTransport.enqueue(
            statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: racesJson(id: 8, name: "Кольцо24")
        )

        #expect(try await h.repo.refreshRaces() == .updated)

        let stored = try await storedRaces(h.dbWriter)
        #expect(stored.count == 1)
        #expect(stored[0].id == 8)
        #expect(stored[0].name == "Кольцо24")
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "races") == "\"v1\"")
    }

    @Test func notModified_leavesDatabaseUntouched() async throws {
        let h = try makeHarness()
        try await seedRace(h.raceStore, id: 8, name: "Cached race")
        try await h.syncMetaStore.upsert(SyncMeta(origin: cloudOrigin, resource: "races", etag: "\"v1\""))
        h.cloudTransport.enqueue(statusCode: 304)

        #expect(try await h.repo.refreshRaces() == .notModified)

        let stored = try await storedRaces(h.dbWriter)
        #expect(stored.count == 1)
        #expect(stored[0].name == "Cached race")
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "races") == "\"v1\"")
    }

    @Test func secondRefresh_sendsStoredEtag() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(
            statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: racesJson(id: 8, name: "Кольцо24")
        )
        h.cloudTransport.enqueue(statusCode: 304)

        _ = try await h.repo.refreshRaces()
        _ = try await h.repo.refreshRaces()

        #expect(h.cloudTransport.recorded.count == 2)
        #expect(h.cloudTransport.recorded[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(h.cloudTransport.recorded[1].value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
    }

    @Test func offline_returnsOfflineAndLeavesDatabaseUntouched() async throws {
        let h = try makeHarness()
        try await seedRace(h.raceStore, id: 8, name: "Cached race")
        h.cloudTransport.enqueueError(URLError(.notConnectedToInternet))

        #expect(try await h.repo.refreshRaces() == .offline)

        let stored = try await storedRaces(h.dbWriter)
        #expect(stored.count == 1)
        #expect(stored[0].name == "Cached race")
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "races") == nil)
    }

    @Test func forbidden_returnsForbidden() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 403)

        #expect(try await h.repo.refreshRaces() == .forbidden)
    }

    @Test func serverError_returnsHttpError() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 500)

        #expect(try await h.repo.refreshRaces() == .httpError(500))
    }

    @Test func success_withoutEtag_storesRacesButSkipsEtagSave() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200, bodyString: racesJson(id: 8, name: "Кольцо24"))

        #expect(try await h.repo.refreshRaces() == .updated)

        #expect(try await storedRaces(h.dbWriter).count == 1)
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "races") == nil)
    }

    @Test func success_withEmptyList_clearsTable() async throws {
        let h = try makeHarness()
        try await seedRace(h.raceStore, id: 99, name: "Stale race")
        h.cloudTransport.enqueue(
            statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: #"{"races":[]}"#
        )

        #expect(try await h.repo.refreshRaces() == .updated)

        #expect(try await storedRaces(h.dbWriter).isEmpty)
    }

    @Test func success_writesDataBeforeEtag() async throws {
        let trace = TraceLog()
        var config = Configuration()
        config.prepareDatabase { db in
            db.trace { trace.append("\($0)") }
        }
        let dbWriter = try AppDatabase(try DatabaseQueue(configuration: config)).writer
        let h = makeHarness(dbWriter: dbWriter)
        h.cloudTransport.enqueue(
            statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: racesJson(id: 8, name: "Кольцо24")
        )

        trace.reset() // отбросить трассы миграций
        _ = try await h.repo.refreshRaces()

        #expect(callSequence(trace.lines) == ["deleteEtag", "replaceAll", "upsertEtag"])
    }

    @Test func localSource_hitsLocalClientAndStoresEtagUnderLocalOrigin() async throws {
        let h = try makeHarness()
        h.localTransport.enqueue(
            statusCode: 200, headers: ["ETag": "\"local-v1\""],
            bodyString: racesJson(id: 8, name: "Кольцо24 (LAN)")
        )

        #expect(try await h.repo.refreshRaces(source: .local) == .updated)

        let stored = try await storedRaces(h.dbWriter)
        #expect(stored.count == 1)
        #expect(stored[0].name == "Кольцо24 (LAN)")
        #expect(try await h.syncMetaStore.getEtag(origin: localOrigin, resource: "races") == "\"local-v1\"")
        // cloud origin остаётся нетронутым
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "races") == nil)
        #expect(h.cloudTransport.callCount == 0)
        #expect(h.localTransport.callCount == 1)
    }

    @Test func localSource_invalidatesStaleCloudEtag() async throws {
        // Прежний cloud-фетч оставил ETag; переключение на Local должно его сбросить, чтобы
        // последующее переключение назад на Cloud не словило 304 против строк, которые Local только что перезаписал.
        let h = try makeHarness()
        try await h.syncMetaStore.upsert(SyncMeta(origin: cloudOrigin, resource: "races", etag: "\"cloud-v1\""))
        h.localTransport.enqueue(
            statusCode: 200, headers: ["ETag": "\"local-v1\""],
            bodyString: racesJson(id: 8, name: "Кольцо24 (LAN)")
        )

        #expect(try await h.repo.refreshRaces(source: .local) == .updated)

        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "races") == nil)
        #expect(try await h.syncMetaStore.getEtag(origin: localOrigin, resource: "races") == "\"local-v1\"")
    }

    @Test func cloudSource_invalidatesStaleLocalEtag() async throws {
        let h = try makeHarness()
        try await h.syncMetaStore.upsert(SyncMeta(origin: localOrigin, resource: "races", etag: "\"local-v1\""))
        h.cloudTransport.enqueue(
            statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: racesJson(id: 8, name: "Кольцо24")
        )

        #expect(try await h.repo.refreshRaces() == .updated)

        #expect(try await h.syncMetaStore.getEtag(origin: localOrigin, resource: "races") == nil)
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "races") == "\"v1\"")
    }
}

/// Собирает исполненные SQL-операторы в маркеры операций репозитория — Swift-аналог callLog'а из
/// фейкового DAO в `RaceRepositoryTest.kt`. `SELECT`/`BEGIN`/`COMMIT` не матчатся ни в одну ветку.
private func callSequence(_ lines: [String]) -> [String] {
    var out: [String] = []
    for line in lines {
        let s = line.lowercased()
        if s.contains("delete from sync_meta") {
            out.append("deleteEtag")
        } else if s.contains("delete from races") {
            out.append("replaceAll")
        } else if s.contains("sync_meta"), s.contains("insert") || s.contains("update") {
            out.append("upsertEtag")
        }
    }
    return out
}

/// Потокобезопасный журнал трассируемого SQL (`Database.trace` дёргается на очереди соединения).
private final class TraceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(line)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}
