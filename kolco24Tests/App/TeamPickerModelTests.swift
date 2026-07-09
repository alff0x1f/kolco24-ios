//
//  TeamPickerModelTests.swift
//  kolco24Tests
//
//  Тесты `TeamPickerModel` — Android-зеркала нет (в Android состояние экранов живёт в composable'ах),
//  пишутся с нуля поверх РЕАЛЬНЫХ store'ов над `AppDatabase.makeInMemory()` (конвенция этапа 2) +
//  `FakeTransport` (этап 3). Проверяем: observation гонок/команд (+split/фильтр/группировка через
//  `TeamPickerLogic`), `raceSelected` (refresh команд + префетч легенды), маппинг `RefreshResult →
//  PickerLoad`, персист `confirm`.
//
//  observation эмитит асинхронно — состояние ждём поллингом с таймаутом.
//

import Foundation
import Testing
@testable import kolco24

@MainActor
struct TeamPickerModelTests {

    // MARK: - Фикстуры

    private func team(id: Int, raceId: Int, name: String, number: String? = nil, categoryId: Int? = nil) -> Team {
        Team(
            id: id, raceId: raceId, teamname: name, startNumber: number, categoryId: categoryId,
            ucount: 2, paidPeople: 2, startTime: 0, finishTime: 0,
            members: [TeamMemberItem(name: "Аня", numberInTeam: 1)]
        )
    }

    private func race(id: Int, date: String, name: String = "Кольцо24") -> Race {
        Race(id: id, name: name, slug: "race-\(id)", date: date, dateEnd: nil,
             place: "Сосновый бор", regStatus: "open")
    }

    private func category(id: Int, raceId: Int, order: Int, name: String) -> kolco24.Category {
        kolco24.Category(id: id, raceId: raceId, code: "C\(id)", shortName: name, name: name, sortOrder: order)
    }

    private func enqueue304s(_ transport: FakeTransport, _ n: Int) {
        for _ in 0..<n { transport.enqueue(statusCode: 304) }
    }

    private func didRequest(_ transport: FakeTransport, suffix: String) -> Bool {
        transport.recorded.contains { $0.url?.absoluteString.hasSuffix(suffix) ?? false }
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeModel(_ env: AppEnvironment, now: Date) -> TeamPickerModel {
        TeamPickerModel(env: env, appModel: AppModel(env: env), now: { now })
    }

    // MARK: - Гонки: split (через splitRaces)

    @Test func racesObservation_splitsCurrentAndArchive() async throws {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let today = todayIso(now: now)
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.raceStore.insertAll([
            race(id: 1, date: today, name: "Текущая"),
            race(id: 2, date: "2000-01-01", name: "Архив"),
        ])
        let model = makeModel(env, now: now)

        model.start()
        await waitUntil { model.races.count == 2 }

        #expect(model.split.current.map(\.id) == [1])
        #expect(model.split.archive.map(\.id) == [2])
    }

    // MARK: - Команды: фильтрация + группировка

    @Test func raceSelected_bindsAndFiltersTeams() async throws {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let transport = FakeTransport()
        enqueue304s(transport, 4)
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.teamStore.insertTeams([
            team(id: 10, raceId: 3, name: "Барсы", number: "1"),
            team(id: 11, raceId: 3, name: "Волки", number: "2"),
        ])
        let model = makeModel(env, now: now)

        await model.raceSelected(3)
        await waitUntil { model.teamsLoaded && model.teams.count == 2 }

        model.searchQuery = "волк"
        #expect(model.filteredTeams.map(\.id) == [11])

        model.searchQuery = "2"
        #expect(model.filteredTeams.map(\.id) == [11])

        model.searchQuery = ""
        #expect(model.filteredTeams.count == 2)
    }

    @Test func sections_groupByCategorySortedWithUncategorizedLast() async throws {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let transport = FakeTransport()
        enqueue304s(transport, 4)
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.teamStore.replaceAllForRace(
            raceId: 3,
            categories: [
                category(id: 100, raceId: 3, order: 2, name: "Спорт"),
                category(id: 101, raceId: 3, order: 1, name: "Новички"),
            ],
            teams: [
                team(id: 10, raceId: 3, name: "A", number: "1", categoryId: 100),
                team(id: 11, raceId: 3, name: "B", number: "2", categoryId: 101),
                team(id: 12, raceId: 3, name: "C", number: "3", categoryId: nil),
            ]
        )
        let model = makeModel(env, now: now)

        await model.raceSelected(3)
        await waitUntil { model.teamsLoaded && model.teams.count == 3 && model.categories.count == 2 }

        // Категории по sortOrder (101 order=1, затем 100 order=2), команды без категории — последней секцией.
        #expect(model.sections.map(\.id) == [101, 100, -1])
        #expect(model.sections.first?.teams.map(\.id) == [11])
    }

    // MARK: - raceSelected: refresh + префетч легенды

    @Test func raceSelected_refreshesTeamsAndPrefetchesLegend() async throws {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let transport = FakeTransport()
        enqueue304s(transport, 4)
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        let model = makeModel(env, now: now)

        await model.raceSelected(7)
        await waitUntil {
            didRequest(transport, suffix: "/app/race/7/teams/")
                && didRequest(transport, suffix: "/app/race/7/legend/")
        }

        #expect(didRequest(transport, suffix: "/app/race/7/teams/"))
        #expect(didRequest(transport, suffix: "/app/race/7/legend/"))
        #expect(model.load == .loaded)
    }

    // MARK: - Маппинг RefreshResult → PickerLoad

    @Test func raceSelected_offline_setsLoadOffline() async throws {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let transport = FakeTransport()
        transport.enqueueError(URLError(.notConnectedToInternet))
        transport.enqueueError(URLError(.notConnectedToInternet))
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        let model = makeModel(env, now: now)

        await model.raceSelected(7)
        #expect(model.load == .offline)
    }

    @Test func raceSelected_forbidden_setsLoadForbidden() async throws {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let transport = FakeTransport()
        transport.enqueue(statusCode: 403)
        transport.enqueue(statusCode: 403)
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        let model = makeModel(env, now: now)

        await model.raceSelected(7)
        #expect(model.load == .forbidden)
    }

    @Test func raceSelected_httpError_setsLoadHttpError() async throws {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let transport = FakeTransport()
        transport.enqueue(statusCode: 500)
        transport.enqueue(statusCode: 500)
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        let model = makeModel(env, now: now)

        await model.raceSelected(7)
        #expect(model.load == .httpError(500))
    }

    // MARK: - confirm

    @Test func confirm_persistsSelectedTeam() async throws {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        let model = makeModel(env, now: now)

        await model.confirm(raceId: 9, teamId: 3)

        let persisted = try await firstValue(env.selectedTeamStore.observe())
        #expect(persisted == SelectedTeam(raceId: 9, teamId: 3))
    }

    // MARK: - openedCompPicker

    @Test func openedCompPicker_refreshesRaces() async throws {
        let now = Date(timeIntervalSince1970: 1_718_000_000)
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: #"{"races":[]}"#)
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        let model = makeModel(env, now: now)

        await model.openedCompPicker()

        #expect(didRequest(transport, suffix: "/app/races/"))
    }
}
