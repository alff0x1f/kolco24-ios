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
        // Позитивный сайд-эффект: `200` Launch A действительно записал ETag гонок (иначе `nil`-тост не
        // отличить от «refresh не запускался»). Origin — дефолтный cloud из `inMemory`.
        let racesEtag = try await env.syncMetaStore.getEtag(origin: "https://cloud.test", resource: "races")
        #expect(racesEtag == "\"v1\"")
    }

    /// Реактивный refresh гонки A завис; пользователь сменил команду на гонку B (обновилась без
    /// ошибок). Поздний offline гонки A НЕ должен показать stale-тост (в Android его гасит
    /// `collectLatest`-отмена). Без guard'а `toastMessage` стал бы «Нет сети…».
    @Test func reactiveRefresh_lateOfflineAfterRaceSwitch_noStaleToast() async throws {
        // teams-запрос гонки 11 висит до `release`; всё остальное отвечает 304.
        let transport = GatedTransport(gateSuffix: "/app/race/11/teams/")
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        let model = AppModel(env: env)

        await model.start() // races → 304, гонок нет → префетча нет

        // Гонка 11: реактивный refresh запускается, его teams-запрос повисает.
        await model.selectTeam(raceId: 11, teamId: 1)
        await waitUntil { transport.requested(suffix: "/app/race/11/teams/") }
        #expect(model.selectedRaceId == 11)

        // Гонка 22: реактивный refresh отрабатывает целиком (всё 304 → тост молчит).
        await model.selectTeam(raceId: 22, teamId: 2)
        await waitUntil { model.selectedRaceId == 22 && transport.requested(suffix: "/app/race/22/teams/") }
        #expect(model.toastMessage == nil)

        // Поздний offline гонки 11: guard обязан подавить stale-тост.
        transport.release(error: URLError(.notConnectedToInternet))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(model.toastMessage == nil)
    }

    // MARK: - Pull-to-refresh (refreshAll / refreshLegend / clearTeam)

    @Test func refreshAll_withSelection_routesErrorToToast() async throws {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: #"{"races":[]}"#) // Launch A
        enqueue304s(transport, 3) // реактивный teams/legend/member_tags
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.teamStore.insertTeams([team(id: 4, raceId: 11)])
        let model = AppModel(env: env)

        await model.start()
        await model.selectTeam(raceId: 11, teamId: 4)
        await waitUntil { didRequest(transport, suffix: "/app/race/11/member_tags/") }
        try? await Task.sleep(for: .milliseconds(50)) // реактивный fan-out дренится
        #expect(model.toastMessage == nil)

        // refreshAll: 4 запроса (races/teams/legend/tags); ровно один обрывается → offline-тост.
        transport.enqueue(statusCode: 304)
        transport.enqueue(statusCode: 304)
        transport.enqueue(statusCode: 304)
        transport.enqueueError(URLError(.notConnectedToInternet))
        await model.refreshAll()

        #expect(model.toastMessage == "Нет сети — не удалось обновить")
        #expect(didRequest(transport, suffix: "/app/races/"))
        #expect(didRequest(transport, suffix: "/app/race/11/teams/"))
    }

    @Test func refreshAll_withNoSelection_requestsOnlyRaces() async throws {
        let transport = FakeTransport()
        // Launch A: гонок нет → nearestRaceId == nil → префетча нет, только /app/races/.
        transport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: #"{"races":[]}"#)
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        let model = AppModel(env: env)

        await model.start()
        #expect(transport.recorded.count == 1)

        transport.enqueue(statusCode: 304)
        await model.refreshAll() // без выбора — только refreshRaces

        #expect(transport.recorded.count == 2)
        #expect(transport.recorded.allSatisfy { $0.url?.absoluteString.hasSuffix("/app/races/") ?? false })
    }

    @Test func refreshLegend_routesErrorToToast() async throws {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: #"{"races":[]}"#) // Launch A
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        let model = AppModel(env: env)

        await model.start()

        transport.enqueueError(URLError(.notConnectedToInternet))
        await model.refreshLegend(raceId: 42)

        #expect(model.toastMessage == "Нет сети — не удалось обновить")
        #expect(didRequest(transport, suffix: "/app/race/42/legend/"))
    }

    @Test func clearTeam_resetsSelectionToNone() async throws {
        let transport = FakeTransport()
        enqueue304s(transport, 12)
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.teamStore.insertTeams([team(id: 5, raceId: 7)])
        try await env.selectedTeamStore.upsert(SelectedTeam(raceId: 7, teamId: 5))
        let model = AppModel(env: env)

        await model.start()
        await waitUntil { model.selectedTeamState == .present(self.team(id: 5, raceId: 7)) }

        await model.clearTeam()
        await waitUntil { model.selectedTeamState == .none }

        #expect(model.selectedTeamState == .none)
        #expect(model.selectedTeamId == nil)
        #expect(model.selectedRaceId == nil)
    }
}
