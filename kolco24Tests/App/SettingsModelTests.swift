//
//  SettingsModelTests.swift
//  kolco24Tests
//
//  Тесты `App/SettingsModel` (этап 9) — Android-зеркала нет (в Android состояние экрана живёт инлайн в
//  composable), пишутся с нуля поверх РЕАЛЬНЫХ store'ов над `AppDatabase.makeInMemory()` + `FakeTransport`.
//
//  Проверяем: derived-тумблер LAN-режима от посеянного lease + реакцию на стрим (пин чужой гонки не
//  тумблерит); `toggleLocalMode` через `FakeTransport` с `data_source: "local"` пинит гонку, крутит
//  busy-цикл (сброс на возврате) и выдаёт тост; `clearTrackEnabled` false при нуле точек и во время записи
//  этой команды; `clearTrack` удаляет точки; `wipeDatabase` чистит таблицы и тостит «База очищена».
//
//  observation/оркестрация эмитят асинхронно — состояние ждём поллингом с таймаутом (иначе `@MainActor`-тест
//  зависнет).
//

import Foundation
import Testing
@testable import kolco24

@MainActor
struct SettingsModelTests {

    // MARK: - Фикстуры

    private func team(id: Int, raceId: Int) -> Team {
        Team(
            id: id, raceId: raceId, teamname: "Барсы", startNumber: "1", categoryId: nil,
            ucount: 2, paidPeople: 2, startTime: 0, finishTime: 0,
            members: [TeamMemberItem(name: "Аня", numberInTeam: 1)]
        )
    }

    private func trackPoint(
        id: String, raceId: Int, teamId: Int,
        uploadedLocal: Bool = true, uploadedCloud: Bool = true
    ) -> TrackPoint {
        TrackPoint(
            id: id, raceId: raceId, teamId: teamId,
            lat: 55.75, lon: 37.62, accuracy: 5,
            gpsTimeMs: 1000, elapsedRealtimeAt: 1000, wallMs: 1000,
            segmentId: "seg-1",
            uploadedLocal: uploadedLocal, uploadedCloud: uploadedCloud
        )
    }

    private func racesJson(id: Int, date: String) -> String {
        """
        {"races":[{"id":\(id),"name":"Кольцо24","slug":"race-\(id)","date":"\(date)",
        "date_end":null,"place":"Сосновый бор","reg_status":"open","is_legend_visible":true}]}
        """
    }

    private func enqueue304s(_ transport: FakeTransport, _ n: Int) {
        for _ in 0..<n { transport.enqueue(statusCode: 304) }
    }

    private func didRequest(_ transport: FakeTransport, suffix: String) -> Bool {
        transport.recorded.contains { $0.url?.absoluteString.hasSuffix(suffix) ?? false }
    }

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

    // MARK: - Derived-тумблер LAN-режима

    /// Посеянный lease на выбранную гонку → тумблер вкл + сабтайтл «Локальный режим до …»; снятие lease
    /// стримом гасит тумблер, сабтайтл возвращается к «Обновление из интернета».
    @Test func localModeToggle_derivedFromLeaseAndStream() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        // Пин гонки 11 на LAN до 5000 (nowMs = 1000 → жив).
        env.leaseHolder.set(RaceLease(raceId: 11, expiresAtMs: 5000))
        let appModel = AppModel(env: env)
        let model = SettingsModel(
            env: env, appModel: appModel, raceId: 11, teamId: 4,
            nowMs: { 1000 }
        )

        #expect(model.localModeOn == true)
        #expect(model.localModeSubtitle.hasPrefix("Локальный режим до"))

        // Снятие пина стримом → тумблер гаснет.
        env.leaseHolder.set(nil)
        await waitUntil { model.localModeOn == false }
        #expect(model.localModeOn == false)
        #expect(model.localModeSubtitle == "Обновление из интернета")
    }

    /// Пин ЧУЖОЙ гонки не тумблерит текущую (скоуп raceId 11, lease на 99).
    @Test func localModeToggle_foreignRaceDoesNotPin() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        env.leaseHolder.set(RaceLease(raceId: 99, expiresAtMs: 5000))
        let appModel = AppModel(env: env)
        let model = SettingsModel(
            env: env, appModel: appModel, raceId: 11, teamId: 4,
            nowMs: { 1000 }
        )

        #expect(model.localModeOn == false)
        #expect(model.localModeSubtitle == "Обновление из интернета")
    }

    // MARK: - toggleLocalMode → busy → тост

    /// `toggleLocalMode(true)` против LAN-манифеста `data_source: "local"` пинит гонку через `AppModel`,
    /// крутит busy-цикл (сброс на возврате) и выдаёт тост «Локальный режим до …».
    @Test func toggleLocalMode_pinsAndResetsBusyAndToasts() async throws {
        let transport = FakeTransport()
        // Launch A races (cloud) в далёком будущем → `nearestRaceId` резолвит её как текущую и в прогреве,
        // и в `enterLocalMode`.
        transport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: racesJson(id: 11, date: "2099-12-31"))
        enqueue304s(transport, 3) // прогрев teams/legend/member_tags (cloud)
        // enterLocalMode: проба sync-манифеста LAN → local → renew + пин.
        transport.enqueue(statusCode: 200, bodyString: #"{"race":11,"data_source":"local","lease_ttl_seconds":3600,"lease_expires_at":null}"#)
        enqueue304s(transport, 6) // LAN fan-out (+ запас)
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        let appModel = AppModel(env: env)

        await appModel.start()
        let model = appModel.makeSettingsModel()
        #expect(model.localModeBusy == false)

        model.toggleLocalMode(true)
        await waitUntil { env.leaseHolder.value != nil && !model.localModeBusy }

        #expect(env.leaseHolder.value?.raceId == 11)
        #expect(model.localModeBusy == false)
        #expect(appModel.toastMessage?.hasPrefix("Локальный режим до") == true)
        #expect(didRequest(transport, suffix: "/app/race/11/sync/"))
    }

    // MARK: - clearTrackEnabled

    /// При нуле точек очистка недоступна.
    @Test func clearTrackEnabled_falseAtZeroPoints() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        let appModel = AppModel(env: env)
        let model = SettingsModel(env: env, appModel: appModel, raceId: 7, teamId: 5)

        await waitUntil { model.trackPointCount == 0 }
        #expect(model.clearTrackEnabled == false)
    }

    /// Точки есть, но рекордер пишет ЭТУ команду → очистка недоступна.
    @Test func clearTrackEnabled_falseWhileRecordingThisTeam() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.trackStore.insertAll([
            trackPoint(id: "p1", raceId: 7, teamId: 5),
            trackPoint(id: "p2", raceId: 7, teamId: 5),
        ])
        let appModel = AppModel(env: env)
        let model = SettingsModel(env: env, appModel: appModel, raceId: 7, teamId: 5)

        await waitUntil { model.trackPointCount == 2 }
        #expect(model.clearTrackEnabled == true) // idle + точки есть

        // Запускаем запись этой команды (NoTrackEngine: фиксов нет, стрим открыт — состояние держится).
        appModel.trackRecorder.start(raceId: 7, teamId: 5)
        #expect(appModel.trackRecorder.state == .recording(teamId: 5))
        #expect(model.clearTrackEnabled == false)
    }

    // MARK: - clearTrack удаляет точки

    @Test func clearTrack_removesPoints() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.trackStore.insertAll([
            trackPoint(id: "p1", raceId: 7, teamId: 5),
            trackPoint(id: "p2", raceId: 7, teamId: 5),
        ])
        let appModel = AppModel(env: env)
        let model = SettingsModel(env: env, appModel: appModel, raceId: 7, teamId: 5)

        await waitUntil { model.trackPointCount == 2 }
        model.clearTrack()

        await waitUntil { model.trackPointCount == 0 }
        #expect(model.trackPointCount == 0)
    }

    // MARK: - wipeDatabase чистит таблицы

    @Test func wipeDatabase_clearsTablesAndToasts() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.raceStore.replaceAll([
            Race(id: 11, name: "Кольцо24", slug: "race-11", date: "2099-12-31", place: "Сосновый бор", regStatus: "open")
        ])
        try await env.teamStore.insertTeams([team(id: 4, raceId: 11)])
        try await env.selectedTeamStore.upsert(SelectedTeam(raceId: 11, teamId: 4))
        let appModel = AppModel(env: env)
        let model = SettingsModel(env: env, appModel: appModel, raceId: 11, teamId: 4)

        model.wipeDatabase()

        await waitUntil { appModel.toastMessage == "База очищена" }
        #expect(appModel.toastMessage == "База очищена")

        // Таблицы пусты, схема жива (observation отдаёт []).
        var races: [Race] = [Race(id: 0, name: "", slug: "", date: "", place: "", regStatus: "")]
        for try await value in env.raceStore.observeRaces() { races = value; break }
        #expect(races.isEmpty)
    }
}
