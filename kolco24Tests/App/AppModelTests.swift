//
//  AppModelTests.swift
//  kolco24Tests
//
//  Тесты `AppModel` — Android-зеркала нет (в Android это состояние живёт инлайн в composable), пишутся
//  с нуля поверх РЕАЛЬНЫХ store'ов над `AppDatabase.makeInMemory()` (конвенция этапа 2) + `FakeTransport`
//  (этап 3). Проверяем: цепочку `SelectedTeamState` (none→loading→present, missing при удалении команды),
//  персист `selectTeam`, Launch A (`/app/races/` + прогрев ближайшей гонки), Launch B (реактивный refresh
//  при смене гонки) и маршрутизацию ошибки refresh в `toastMessage`.
//
//  observation эмитит асинхронно — состояние ждём поллингом с таймаутом (иначе `@MainActor`-тест зависнет).
//

import Foundation
import Testing
@testable import kolco24

@MainActor
struct AppModelTests {

    // MARK: - Фикстуры

    private func team(id: Int, raceId: Int, name: String = "Команда") -> Team {
        Team(
            id: id, raceId: raceId, teamname: name, startNumber: "1", categoryId: nil,
            ucount: 2, paidPeople: 2, startTime: 0, finishTime: 0,
            members: [TeamMemberItem(name: "Аня", numberInTeam: 1)]
        )
    }

    private func racesJson(id: Int, date: String) -> String {
        """
        {"races":[{"id":\(id),"name":"Кольцо24","slug":"race-\(id)","date":"\(date)",
        "date_end":null,"place":"Сосновый бор","reg_status":"open","is_legend_visible":true}]}
        """
    }

    /// Заготавливает `n` ответов `304` — безопасны для любого эндпоинта (тело не парсится).
    private func enqueue304s(_ transport: FakeTransport, _ n: Int) {
        for _ in 0..<n { transport.enqueue(statusCode: 304) }
    }

    /// Полные URL перехваченных запросов. `URL.path` срезает завершающий слэш, а эндпоинты подписывают
    /// путь **со** слэшем — сверяем по `absoluteString`, чтобы `/app/races/` матчился как есть.
    private func didRequest(_ transport: FakeTransport, suffix: String) -> Bool {
        transport.recorded.contains { $0.url?.absoluteString.hasSuffix(suffix) ?? false }
    }

    /// Поллинг условия на главном акторе с таймаутом (аналог ожидания эмиссии observation).
    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - SelectedTeamState

    @Test func noSelection_resolvesToNone() async throws {
        let transport = FakeTransport()
        enqueue304s(transport, 4)
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        let model = AppModel(env: env)

        await model.start()
        await waitUntil { model.selectedTeamState == .none }

        #expect(model.selectedTeamState == .none)
        #expect(model.selectedTeamId == nil)
        #expect(model.selectedRaceId == nil)
    }

    @Test func presentSelection_resolvesToPresent() async throws {
        let transport = FakeTransport()
        enqueue304s(transport, 8)
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.teamStore.insertTeams([team(id: 5, raceId: 7, name: "Барсы")])
        try await env.selectedTeamStore.upsert(SelectedTeam(raceId: 7, teamId: 5))
        let model = AppModel(env: env)

        await model.start()
        await waitUntil { model.selectedTeamState == .present(self.team(id: 5, raceId: 7, name: "Барсы")) }

        #expect(model.selectedTeamState == .present(team(id: 5, raceId: 7, name: "Барсы")))
        #expect(model.selectedTeamId == 5)
        #expect(model.selectedRaceId == 7)
    }

    @Test func selectionToUnknownTeam_resolvesToMissing() async throws {
        let transport = FakeTransport()
        enqueue304s(transport, 8)
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        // Строка выбора есть, но команды с таким id в БД нет — «команда исчезла».
        try await env.selectedTeamStore.upsert(SelectedTeam(raceId: 7, teamId: 999))
        let model = AppModel(env: env)

        await model.start()
        await waitUntil { model.selectedTeamState == .missing }

        #expect(model.selectedTeamState == .missing)
    }

    @Test func teamDeletedAfterPresent_transitionsToMissing() async throws {
        let transport = FakeTransport()
        enqueue304s(transport, 8)
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.teamStore.insertTeams([team(id: 5, raceId: 7)])
        try await env.selectedTeamStore.upsert(SelectedTeam(raceId: 7, teamId: 5))
        let model = AppModel(env: env)

        await model.start()
        await waitUntil { model.selectedTeamState == .present(self.team(id: 5, raceId: 7)) }

        // Сервер удалил команду (resync очищает строки этой гонки).
        try await env.teamStore.deleteTeamsForRace(7)
        await waitUntil { model.selectedTeamState == .missing }

        #expect(model.selectedTeamState == .missing)
    }

    // MARK: - selectTeam

    @Test func selectTeam_persistsAndSwitchesState() async throws {
        let transport = FakeTransport()
        enqueue304s(transport, 12)
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.teamStore.insertTeams([team(id: 3, raceId: 9, name: "Волки")])
        let model = AppModel(env: env)

        await model.start()
        await waitUntil { model.selectedTeamState == .none }
        #expect(model.selectedTeamState == .none)

        await model.selectTeam(raceId: 9, teamId: 3)
        await waitUntil { model.selectedTeamState == .present(self.team(id: 3, raceId: 9, name: "Волки")) }

        #expect(model.selectedTeamState == .present(team(id: 3, raceId: 9, name: "Волки")))
        let persisted = try await firstValue(env.selectedTeamStore.observe())
        #expect(persisted == SelectedTeam(raceId: 9, teamId: 3))
    }

    // MARK: - Launch A (стартовый refresh + прогрев)

    @Test func start_refreshesRacesAndPrefetchesNearest() async throws {
        let fixedNow = Date(timeIntervalSince1970: 1_718_000_000)
        let today = todayIso(now: fixedNow)
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: racesJson(id: 5, date: today))
        enqueue304s(transport, 6) // прогрев teams/legend/member_tags
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        let model = AppModel(env: env, now: { fixedNow })

        await model.start() // Launch A ждёт префетч-fan-out

        #expect(didRequest(transport, suffix: "/app/races/"))
        #expect(didRequest(transport, suffix: "/app/race/5/teams/"))
        #expect(didRequest(transport, suffix: "/app/race/5/legend/"))
        #expect(didRequest(transport, suffix: "/app/race/5/member_tags/"))
    }

    @Test func start_withNoCurrentRace_skipsPrefetch() async throws {
        let transport = FakeTransport()
        // Гонок нет → nearestRaceId == nil → префетча нет, только один вызов /app/races/.
        transport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: #"{"races":[]}"#)
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        let model = AppModel(env: env)

        await model.start()

        #expect(transport.recorded.count == 1)
        #expect(didRequest(transport, suffix: "/app/races/"))
    }

    // MARK: - Launch B (реактивный refresh при смене гонки)

    @Test func selectingTeam_triggersReactiveRefresh() async throws {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: #"{"races":[]}"#)
        enqueue304s(transport, 12)
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.teamStore.insertTeams([team(id: 4, raceId: 11)])
        let model = AppModel(env: env)

        await model.start()
        await model.selectTeam(raceId: 11, teamId: 4)

        await waitUntil {
            didRequest(transport, suffix: "/app/race/11/teams/")
                && didRequest(transport, suffix: "/app/race/11/legend/")
                && didRequest(transport, suffix: "/app/race/11/member_tags/")
        }

        #expect(didRequest(transport, suffix: "/app/race/11/teams/"))
        #expect(didRequest(transport, suffix: "/app/race/11/legend/"))
        #expect(didRequest(transport, suffix: "/app/race/11/member_tags/"))
    }

    // MARK: - Ошибки refresh → toast

    @Test func reactiveRefreshOffline_setsToast() async throws {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: #"{"races":[]}"#)
        // Все три реактивных запроса обрываются — offline.
        transport.enqueueError(URLError(.notConnectedToInternet))
        transport.enqueueError(URLError(.notConnectedToInternet))
        transport.enqueueError(URLError(.notConnectedToInternet))
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.teamStore.insertTeams([team(id: 4, raceId: 11)])
        let model = AppModel(env: env)

        await model.start()
        await model.selectTeam(raceId: 11, teamId: 4)

        await waitUntil { model.toastMessage != nil }
        #expect(model.toastMessage == "Нет сети — не удалось обновить")
    }

    @Test func successfulRefresh_leavesToastNil() async throws {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: #"{"races":[]}"#)
        enqueue304s(transport, 12)
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.teamStore.insertTeams([team(id: 4, raceId: 11)])
        let model = AppModel(env: env)

        await model.start()
        await model.selectTeam(raceId: 11, teamId: 4)

        await waitUntil {
            didRequest(transport, suffix: "/app/race/11/member_tags/")
        }
        // Дать реактивному fan-out дойти до конца.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.toastMessage == nil)
    }
}
