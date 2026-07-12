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

    // MARK: - LAN-режим (этап 9)

    /// Подтверждает: при посеянном lease (гонка запинена к LAN) смена команды идёт по LAN-origin —
    /// сперва heartbeat `/sync/`, затем fan-out teams/legend/member_tags с `http://local.test`.
    @Test func seededLease_teamChange_probesSyncAndUsesLanOrigin() async throws {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: #"{"races":[]}"#) // Launch A races (cloud)
        enqueue304s(transport, 12) // probe + LAN fan-out (+ запас)
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.teamStore.insertTeams([team(id: 4, raceId: 11)])
        // Пин гонки 11 на LAN на far-future (переживает wall-clock `nowMs` пин-гарда).
        env.leaseHolder.set(RaceLease(raceId: 11, expiresAtMs: .max))
        let model = AppModel(env: env)

        await model.start()
        await model.selectTeam(raceId: 11, teamId: 4)

        await waitUntil {
            didRequest(transport, suffix: "/app/race/11/sync/")
                && didRequest(transport, suffix: "/app/race/11/teams/")
        }

        // Heartbeat пробы sync-манифеста ушёл на LAN.
        #expect(transport.recorded.contains {
            ($0.url?.absoluteString.hasPrefix("http://local.test")) == true
                && ($0.url?.absoluteString.hasSuffix("/app/race/11/sync/")) == true
        })
        // Fan-out teams запинённой гонки ушёл на LAN-origin, а не cloud.
        #expect(transport.recorded.contains {
            ($0.url?.absoluteString.hasPrefix("http://local.test")) == true
                && ($0.url?.absoluteString.hasSuffix("/app/race/11/teams/")) == true
        })
    }

    /// `toggleLocalMode(true)` против LAN-манифеста `data_source: "local"` пинит гонку, крутит busy-цикл
    /// (сброс на возврате) и выдаёт тост «Локальный режим до …».
    @Test func toggleLocalMode_withLocalDataSource_pinsRaceAndResetsBusy() async throws {
        let transport = FakeTransport()
        // Launch A races (cloud): гонка в далёком будущем → и прогрев Launch A, и `enterLocalMode`
        // (использует РЕАЛЬНЫЙ `todayIso()`) резолвят её через `nearestRaceId` как текущую.
        transport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: racesJson(id: 11, date: "2099-12-31"))
        enqueue304s(transport, 3) // прогрев teams/legend/member_tags (cloud, ещё не запинено)
        // enterLocalMode: проба sync-манифеста LAN → local → renew + пин.
        transport.enqueue(statusCode: 200, bodyString: #"{"race":11,"data_source":"local","lease_ttl_seconds":3600,"lease_expires_at":null}"#)
        enqueue304s(transport, 6) // LAN fan-out (+ запас)
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        let model = AppModel(env: env)

        await model.start()
        #expect(env.leaseHolder.value == nil)

        model.toggleLocalMode(true)
        await waitUntil { env.leaseHolder.value != nil && !model.localModeBusy }

        #expect(env.leaseHolder.value?.raceId == 11)
        #expect(model.localModeBusy == false)
        #expect(model.toastMessage?.hasPrefix("Локальный режим до") == true)
        #expect(didRequest(transport, suffix: "/app/race/11/sync/"))
    }

    /// `toggleLocalMode(false)` (выход): безусловно снимает пин, cloud-refresh успешен → тост
    /// «Обновлено из интернета», busy сброшен.
    @Test func toggleLocalMode_off_clearsLeaseAndToastsCloudUpdated() async throws {
        let transport = FakeTransport()
        enqueue304s(transport, 8) // exit fan-out (races/teams/legend/member_tags) + запас
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.teamStore.insertTeams([team(id: 4, raceId: 11)])
        try await env.selectedTeamStore.upsert(SelectedTeam(raceId: 11, teamId: 4))
        // Гонка 11 запинена — выход должен снять пин.
        env.leaseHolder.set(RaceLease(raceId: 11, expiresAtMs: .max))
        let model = AppModel(env: env)

        model.toggleLocalMode(false)
        await waitUntil { env.leaseHolder.value == nil && !model.localModeBusy }

        #expect(env.leaseHolder.value == nil)
        #expect(model.localModeBusy == false)
        #expect(model.toastMessage == "Обновлено из интернета")
    }

    /// Двойной вход `toggleLocalMode(true)`, пока первый в полёте (проба `/sync/` висит в гейте):
    /// guard `!localModeBusy` глотает второй вызов — ровно одна проба `/sync/` в логе.
    @Test func toggleLocalMode_doubleEntry_runsSingleSequence() async throws {
        let transport = GatedTransport(gateSuffix: "/app/race/11/sync/")
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.teamStore.insertTeams([team(id: 4, raceId: 11)])
        try await env.selectedTeamStore.upsert(SelectedTeam(raceId: 11, teamId: 4))
        let model = AppModel(env: env)

        // Первый вход — проба `/sync/` повисает в гейте.
        model.toggleLocalMode(true)
        await waitUntil { transport.requested(suffix: "/app/race/11/sync/") }
        #expect(model.localModeBusy == true)

        // Второй вход, пока первый в полёте — проглочен guard'ом.
        model.toggleLocalMode(true)
        try? await Task.sleep(for: .milliseconds(50))

        let syncProbes = transport.recorded.filter {
            $0.url?.absoluteString.hasSuffix("/app/race/11/sync/") ?? false
        }.count
        #expect(syncProbes == 1)

        // Отпускаем гейт → цикл завершается, busy сбрасывается.
        transport.release(statusCode: 304)
        await waitUntil { model.localModeBusy == false }
        #expect(model.localModeBusy == false)
    }

    // MARK: - Тост-маппинг LAN-исходов (таблица тостов)

    @Test func localModeToast_mapsEveryOutcomeToString() {
        let expiresAtMs: Int64 = 1_800_000_000_000
        #expect(AppModel.localModeToast(.pinnedUntil(expiresAtMs: expiresAtMs, dataStale: false))
            .hasPrefix("Локальный режим до"))
        #expect(AppModel.localModeToast(.pinnedUntil(expiresAtMs: expiresAtMs, dataStale: false))
            .contains("данные не обновлены") == false)
        #expect(AppModel.localModeToast(.pinnedUntil(expiresAtMs: expiresAtMs, dataStale: true))
            .contains("(данные не обновлены)"))
        #expect(AppModel.localModeToast(.localNoPin) == "Обновлено из интернета")
        #expect(AppModel.localModeToast(.cloudUpdated) == "Обновлено из интернета")
        #expect(AppModel.localModeToast(.localUnreachable) == "Локальный сервер недоступен")
        #expect(AppModel.localModeToast(.offline) == "Нет сети")
        #expect(AppModel.localModeToast(.noRace) == "Гонка не выбрана")
    }

    // MARK: - Статус часов (этап 11)

    /// Мутабельные провайдеры времени для управляемого `TrustedClock` (как `Fakes` в `TrustedClockTests`).
    private final class ClockFakes: @unchecked Sendable {
        var elapsed: Int64
        var wall: Int64
        var boot: Int?
        init(elapsed: Int64, wall: Int64, boot: Int?) {
            self.elapsed = elapsed
            self.wall = wall
            self.boot = boot
        }
    }

    /// `AppModel` — единственный потребитель `TrustedClock.statusUpdates`: после `start()` подписка
    /// републикует статус в `clockStatus`. Загоняем часы в скью (якорь + сдвиг wall) → свойство
    /// становится `.skewed`.
    @Test func start_republishesClockStatusFromTrustedClock() async throws {
        let transport = FakeTransport()
        enqueue304s(transport, 4)
        let fakes = ClockFakes(elapsed: 1_000, wall: 0, boot: 1)
        let clock = TrustedClock(
            elapsedProvider: { [unowned fakes] in fakes.elapsed },
            wallProvider: { [unowned fakes] in fakes.wall },
            bootCountProvider: { [unowned fakes] in fakes.boot }
        )
        let env = try AppEnvironment.inMemory(transport: transport.handle, trustedClock: clock)
        let model = AppModel(env: env)

        await model.start()
        // До синхры — noSync (начальное значение, прочитанное подпиской).
        await waitUntil { model.clockStatus == .noSync }
        #expect(model.clockStatus == .noSync)

        // Заякориться (wall == trusted → сперва .ok), затем сдвинуть wall на >60 с → .skewed.
        await clock.onServerTime(serverMs: 1_000_000, anchorElapsed: 1_000, wallNow: 1_000_000, bootNow: 1)
        fakes.wall = 1_000_000 + 90_000
        await clock.recomputeStatus()

        await waitUntil { model.clockStatus == .skewed(skewMs: 90_000) }
        #expect(model.clockStatus == .skewed(skewMs: 90_000))
    }

    // MARK: - Тема (seed + persist)

    /// `themeMode` засеивается из `ThemePreference` в `init`; сеттер персистит через стор; новый
    /// `AppModel` над тем же (обновлённым) стором отражает сохранённое значение.
    @Test func themeMode_seedsFromPrefAndPersists() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        // Пре-сид: тёмная тема в сторе → новый AppModel её отражает.
        env.themePreference.setMode(.dark)
        let model = AppModel(env: env)
        #expect(model.themeMode == .dark)

        // Сеттер персистит через стор (didSet → ThemePreference.setMode).
        model.themeMode = .light
        #expect(env.themePreference.mode == .light)

        // Свежий AppModel над обновлённым стором читает сохранённое значение.
        let model2 = AppModel(env: env)
        #expect(model2.themeMode == .light)
    }
}
