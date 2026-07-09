//
//  TeamRepositoryTests.swift
//  kolco24Tests
//
//  Зеркало `data/TeamRepositoryTest.kt` (18 кейсов) поверх РЕАЛЬНЫХ store'ов над
//  `AppDatabase.makeInMemory()` (конвенция этапа 2 — без фейков) + `FakeTransport` (замена
//  `MockWebServer`). Отдельный cloud/local `FakeTransport` играет роль двух `MockWebServer`'ов —
//  по числу перехваченных запросов проверяем, какой сервер дёрнули.
//
//  Всё из `RaceRepositoryTests` ПЛЮС полная pin-guard-матрица (pinned-cloud / unpinned-local →
//  skipped; pin появился/исчез в полёте → после 200 не персистит; unpinned-cloud работает) и
//  изоляция по raceId. Порядок «данные → потом ETag» проверяется трассировкой SQL реальной БД
//  (`Database.trace`) — Swift-аналог callLog'а из фейкового DAO в Kotlin.
//

import Foundation
import GRDB
import Testing
@testable import kolco24

struct TeamRepositoryTests {

    private let cloudOrigin = "https://cloud.test"
    private let localOrigin = "http://local.test"

    // MARK: - Фикстуры

    private func teamsJson() -> String {
        """
        {
          "race": 8,
          "categories": [
            { "id": 1, "code": "M", "short_name": "Муж", "name": "Мужская", "order": 2 }
          ],
          "teams": [
            {
              "id": 201,
              "teamname": "Барсы",
              "start_number": "201",
              "category2": 1,
              "ucount": 2,
              "paid_people": 2.0,
              "start_time": 1718200000,
              "finish_time": 0,
              "members": [
                { "name": "Иван", "number_in_team": 1 },
                { "name": "Пётр", "number_in_team": 2 }
              ]
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
        let repo: TeamRepository
        let dbWriter: any DatabaseWriter
        let teamStore: TeamStore
        let syncMetaStore: SyncMetaStore
        let cloudTransport: FakeTransport
        let localTransport: FakeTransport
    }

    private func makeHarness(
        dbWriter: any DatabaseWriter,
        isRacePinned: @escaping (Int) -> Bool = { _ in false }
    ) -> Harness {
        let cloudTransport = FakeTransport()
        let localTransport = FakeTransport()
        let teamStore = TeamStore(dbWriter)
        let selectedTeamStore = SelectedTeamStore(dbWriter)
        let syncMetaStore = SyncMetaStore(dbWriter)
        let repo = TeamRepository(
            apiClient: makeApiClient(baseURL: cloudOrigin, transport: cloudTransport),
            teamStore: teamStore,
            selectedTeamStore: selectedTeamStore,
            syncMetaStore: syncMetaStore,
            origin: cloudOrigin,
            localApiClient: makeApiClient(baseURL: localOrigin, transport: localTransport),
            localOrigin: localOrigin,
            isRacePinned: isRacePinned
        )
        return Harness(
            repo: repo,
            dbWriter: dbWriter,
            teamStore: teamStore,
            syncMetaStore: syncMetaStore,
            cloudTransport: cloudTransport,
            localTransport: localTransport
        )
    }

    private func makeHarness(
        isRacePinned: @escaping (Int) -> Bool = { _ in false }
    ) throws -> Harness {
        makeHarness(dbWriter: try AppDatabase.makeInMemory().writer, isRacePinned: isRacePinned)
    }

    private func storedTeams(_ dbWriter: any DatabaseWriter, raceId: Int) async throws -> [Team] {
        try await dbWriter.read { db in
            try Team.fetchAll(db, sql: "SELECT * FROM teams WHERE raceId = ? ORDER BY id", arguments: [raceId])
        }
    }

    private func storedCategories(_ dbWriter: any DatabaseWriter, raceId: Int) async throws -> [kolco24.Category] {
        try await dbWriter.read { db in
            try kolco24.Category.fetchAll(db, sql: "SELECT * FROM categories WHERE raceId = ? ORDER BY id", arguments: [raceId])
        }
    }

    private func seedTeam(_ store: TeamStore, id: Int, raceId: Int, name: String) async throws {
        try await store.insertTeams([
            Team(id: id, raceId: raceId, teamname: name, startNumber: nil, categoryId: nil,
                 ucount: 0, paidPeople: 0.0, startTime: 0, finishTime: 0, members: []),
        ])
    }

    // MARK: - Зеркало TeamRepositoryTest.kt

    @Test func success_mapsEntitiesAndStoresEtag() async throws {
        let h = try makeHarness()
        try await seedTeam(h.teamStore, id: 99, raceId: 8, name: "Stale")
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: teamsJson())

        #expect(try await h.repo.refreshTeams(8) == .updated)

        let teams = try await storedTeams(h.dbWriter, raceId: 8)
        #expect(teams.count == 1)
        let team = teams[0]
        #expect(team.id == 201)
        #expect(team.raceId == 8)
        #expect(team.teamname == "Барсы")
        #expect(team.startNumber == "201")
        #expect(team.categoryId == 1)
        #expect(team.paidPeople == 2.0)
        #expect(team.members.count == 2)
        #expect(team.members[0].name == "Иван")
        #expect(team.members[1].numberInTeam == 2)

        let categories = try await storedCategories(h.dbWriter, raceId: 8)
        #expect(categories.count == 1)
        #expect(categories[0].shortName == "Муж")
        #expect(categories[0].sortOrder == 2)

        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/teams") == "\"v1\"")
    }

    @Test func success_writesDataBeforeEtag() async throws {
        let trace = TraceLog()
        var config = Configuration()
        config.prepareDatabase { db in
            db.trace { trace.append("\($0)") }
        }
        let dbWriter = try AppDatabase(try DatabaseQueue(configuration: config)).writer
        let h = makeHarness(dbWriter: dbWriter)
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: teamsJson())

        trace.reset() // отбросить трассы миграций
        _ = try await h.repo.refreshTeams(8)

        #expect(callSequenceTeams(trace.lines) == ["deleteEtag", "replaceAllForRace", "upsertEtag"])
    }

    @Test func success_withoutEtag_storesTeamsButSkipsEtagSave() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200, bodyString: teamsJson())

        #expect(try await h.repo.refreshTeams(8) == .updated)

        #expect(try await storedTeams(h.dbWriter, raceId: 8).count == 1)
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/teams") == nil)
    }

    @Test func notModified_leavesDataUntouched() async throws {
        let h = try makeHarness()
        try await seedTeam(h.teamStore, id: 201, raceId: 8, name: "Cached")
        try await h.syncMetaStore.upsert(SyncMeta(origin: cloudOrigin, resource: "race/8/teams", etag: "\"v1\""))
        h.cloudTransport.enqueue(statusCode: 304)

        #expect(try await h.repo.refreshTeams(8) == .notModified)

        let teams = try await storedTeams(h.dbWriter, raceId: 8)
        #expect(teams.count == 1)
        #expect(teams[0].teamname == "Cached")
    }

    @Test func offline_returnsOfflineAndLeavesDataUntouched() async throws {
        let h = try makeHarness()
        try await seedTeam(h.teamStore, id: 201, raceId: 8, name: "Cached")
        try await h.syncMetaStore.upsert(SyncMeta(origin: cloudOrigin, resource: "race/8/teams", etag: "\"existing\""))
        h.cloudTransport.enqueueError(URLError(.notConnectedToInternet))

        #expect(try await h.repo.refreshTeams(8) == .offline)

        #expect(try await storedTeams(h.dbWriter, raceId: 8).count == 1)
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/teams") == "\"existing\"")
    }

    @Test func forbidden_returnsForbidden() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 403)

        #expect(try await h.repo.refreshTeams(8) == .forbidden)
    }

    @Test func serverError_returnsHttpError() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 500)

        #expect(try await h.repo.refreshTeams(8) == .httpError(500))
    }

    @Test func differentRaceIds_useDifferentSyncResources() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"a\""], bodyString: teamsJson())
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"b\""], bodyString: teamsJson())

        _ = try await h.repo.refreshTeams(8)
        _ = try await h.repo.refreshTeams(9)

        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/teams") == "\"a\"")
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/9/teams") == "\"b\"")
        #expect(h.cloudTransport.recorded[0].url!.absoluteString.contains("/app/race/8/teams/"))
        #expect(h.cloudTransport.recorded[1].url!.absoluteString.contains("/app/race/9/teams/"))
    }

    @Test func secondRefresh_sendsStoredEtagForSameRace() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: teamsJson())
        h.cloudTransport.enqueue(statusCode: 304)

        _ = try await h.repo.refreshTeams(8)
        _ = try await h.repo.refreshTeams(8)

        #expect(h.cloudTransport.recorded.count == 2)
        #expect(h.cloudTransport.recorded[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(h.cloudTransport.recorded[1].value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
    }

    @Test func selectTeam_upsertsSingleRow() async throws {
        let h = try makeHarness()

        try await h.repo.selectTeam(raceId: 8, teamId: 201)
        #expect(try await firstValue(h.repo.selectedTeam) == SelectedTeam(id: 1, raceId: 8, teamId: 201))

        try await h.repo.selectTeam(raceId: 9, teamId: 305)
        #expect(try await firstValue(h.repo.selectedTeam) == SelectedTeam(id: 1, raceId: 9, teamId: 305))
    }

    @Test func localSource_hitsLocalClientAndStoresEtagUnderLocalOrigin() async throws {
        let h = try makeHarness(isRacePinned: { _ in true })
        h.localTransport.enqueue(statusCode: 200, headers: ["ETag": "\"local-v1\""], bodyString: teamsJson())

        #expect(try await h.repo.refreshTeams(8, source: .local) == .updated)

        #expect(try await storedTeams(h.dbWriter, raceId: 8).count == 1)
        #expect(try await h.syncMetaStore.getEtag(origin: localOrigin, resource: "race/8/teams") == "\"local-v1\"")
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/teams") == nil)
        #expect(h.cloudTransport.callCount == 0)
        #expect(h.localTransport.callCount == 1)
    }

    @Test func localSource_invalidatesStaleCloudEtag() async throws {
        let h = try makeHarness(isRacePinned: { _ in true })
        try await h.syncMetaStore.upsert(SyncMeta(origin: cloudOrigin, resource: "race/8/teams", etag: "\"cloud-v1\""))
        h.localTransport.enqueue(statusCode: 200, headers: ["ETag": "\"local-v1\""], bodyString: teamsJson())

        #expect(try await h.repo.refreshTeams(8, source: .local) == .updated)

        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/teams") == nil)
        #expect(try await h.syncMetaStore.getEtag(origin: localOrigin, resource: "race/8/teams") == "\"local-v1\"")
    }

    @Test func cloudSource_invalidatesStaleLocalEtag() async throws {
        let h = try makeHarness()
        try await h.syncMetaStore.upsert(SyncMeta(origin: localOrigin, resource: "race/8/teams", etag: "\"local-v1\""))
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: teamsJson())

        #expect(try await h.repo.refreshTeams(8) == .updated)

        #expect(try await h.syncMetaStore.getEtag(origin: localOrigin, resource: "race/8/teams") == nil)
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/teams") == "\"v1\"")
    }

    @Test func cloudSource_pinnedRace_skipsWithoutTouchingNetworkOrData() async throws {
        let h = try makeHarness(isRacePinned: { _ in true })
        try await seedTeam(h.teamStore, id: 201, raceId: 8, name: "Cached")

        #expect(try await h.repo.refreshTeams(8, source: .cloud) == .skipped)

        #expect(h.cloudTransport.callCount == 0)
        let teams = try await storedTeams(h.dbWriter, raceId: 8)
        #expect(teams.count == 1)
        #expect(teams[0].teamname == "Cached")
    }

    @Test func cloudSource_pinAppearingMidFlight_doesNotPersist() async throws {
        // false на входном guard'е, true на пред-персист-повторе — пин «прилетел», пока cloud-фетч
        // был в полёте.
        let counter = CallCounter()
        let h = try makeHarness(isRacePinned: { _ in counter.next() > 0 })
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: teamsJson())

        #expect(try await h.repo.refreshTeams(8, source: .cloud) == .skipped)

        #expect(try await storedTeams(h.dbWriter, raceId: 8).isEmpty)
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/teams") == nil)
    }

    @Test func localSource_unpinnedRace_skipsWithoutTouchingNetworkOrData() async throws {
        let h = try makeHarness(isRacePinned: { _ in false })
        try await seedTeam(h.teamStore, id: 201, raceId: 8, name: "Cached")

        #expect(try await h.repo.refreshTeams(8, source: .local) == .skipped)

        #expect(h.localTransport.callCount == 0)
        let teams = try await storedTeams(h.dbWriter, raceId: 8)
        #expect(teams.count == 1)
        #expect(teams[0].teamname == "Cached")
    }

    @Test func localSource_unpinDisappearingMidFlight_doesNotPersist() async throws {
        // true на входном guard'е, false на пред-персист-повторе — локальный режим выключили, пока
        // LAN-фетч был в полёте.
        let counter = CallCounter()
        let h = try makeHarness(isRacePinned: { _ in counter.next() == 0 })
        h.localTransport.enqueue(statusCode: 200, headers: ["ETag": "\"local-v1\""], bodyString: teamsJson())

        #expect(try await h.repo.refreshTeams(8, source: .local) == .skipped)

        #expect(try await storedTeams(h.dbWriter, raceId: 8).isEmpty)
        #expect(try await h.syncMetaStore.getEtag(origin: localOrigin, resource: "race/8/teams") == nil)
    }

    @Test func unpinnedCloud_behaviorUnchanged() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: teamsJson())

        #expect(try await h.repo.refreshTeams(8, source: .cloud) == .updated)

        #expect(try await storedTeams(h.dbWriter, raceId: 8).count == 1)
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/teams") == "\"v1\"")
    }
}

/// Собирает исполненные SQL-операторы в маркеры операций репозитория — Swift-аналог callLog'а из
/// фейкового DAO в `TeamRepositoryTest.kt`. `replaceAllForRace` матчится по `DELETE FROM teams`
/// (второй `DELETE FROM categories` и вставки игнорируются, чтобы дать один маркер).
private func callSequenceTeams(_ lines: [String]) -> [String] {
    var out: [String] = []
    for line in lines {
        let s = line.lowercased()
        if s.contains("delete from sync_meta") {
            out.append("deleteEtag")
        } else if s.contains("delete from teams") {
            out.append("replaceAllForRace")
        } else if s.contains("sync_meta"), s.contains("insert") || s.contains("update") {
            out.append("upsertEtag")
        }
    }
    return out
}
