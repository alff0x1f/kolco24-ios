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

/// Потокобезопасный рекордер id-удалений (замыкание `deleteMapFile` — `@Sendable`, зовётся из `Task`).
private final class DeletedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _ids: [Int] = []
    func record(_ id: Int) {
        lock.lock(); defer { lock.unlock() }
        _ids.append(id)
    }
    var ids: [Int] {
        lock.lock(); defer { lock.unlock() }
        return _ids
    }
}

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

    /// `wipeDatabase` также снимает LAN-пин (порт `AppContainer.clearDatabase()`: тумблер не должен
    /// указывать на стёртую гонку) — держатель обнуляется, стрим гасит тумблер.
    @Test func wipeDatabase_clearsRaceLease() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        env.leaseHolder.set(RaceLease(raceId: 11, expiresAtMs: 5000))
        let appModel = AppModel(env: env)
        let model = SettingsModel(env: env, appModel: appModel, raceId: 11, teamId: 4, nowMs: { 1000 })

        #expect(model.localModeOn == true) // до wipe гонка запинена
        model.wipeDatabase()

        await waitUntil { env.leaseHolder.value == nil }
        #expect(env.leaseHolder.value == nil)
        await waitUntil { model.localModeOn == false }
        #expect(model.localModeOn == false)
    }

    // MARK: - clearTrackEnabled — запись ДРУГОЙ команды

    /// Точки есть, а рекордер пишет ДРУГУЮ команду (не скоуп) → очистка доступна.
    @Test func clearTrackEnabled_trueWhileRecordingDifferentTeam() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.trackStore.insertAll([
            trackPoint(id: "p1", raceId: 7, teamId: 5),
            trackPoint(id: "p2", raceId: 7, teamId: 5),
        ])
        let appModel = AppModel(env: env)
        let model = SettingsModel(env: env, appModel: appModel, raceId: 7, teamId: 5)

        await waitUntil { model.trackPointCount == 2 }
        // Запись ДРУГОЙ команды (99), а скоуп настроек — команда 5.
        appModel.trackRecorder.start(raceId: 7, teamId: 99)
        #expect(appModel.trackRecorder.state == .recording(teamId: 99))
        #expect(model.clearTrackEnabled == true)
    }

    // MARK: - clearTrack — no-op во время записи

    /// `clearTrack()` во время записи ЭТОЙ команды — no-op (guard `state == .idle`): точки не тронуты.
    @Test func clearTrack_noOpWhileRecording() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.trackStore.insertAll([
            trackPoint(id: "p1", raceId: 7, teamId: 5),
            trackPoint(id: "p2", raceId: 7, teamId: 5),
        ])
        let appModel = AppModel(env: env)
        let model = SettingsModel(env: env, appModel: appModel, raceId: 7, teamId: 5)

        await waitUntil { model.trackPointCount == 2 }
        appModel.trackRecorder.start(raceId: 7, teamId: 5)
        #expect(appModel.trackRecorder.state == .recording(teamId: 5))

        model.clearTrack() // guard state == .idle → no-op
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.trackPointCount == 2) // точки не тронуты
    }

    // MARK: - resetTeam делегирует clearTeam

    /// `resetTeam()` делегирует `AppModel.clearTeam()` — выбранная команда сбрасывается в `.none`.
    @Test func resetTeam_delegatesToClearTeam() async throws {
        let transport = FakeTransport()
        enqueue304s(transport, 12)
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.teamStore.insertTeams([team(id: 4, raceId: 11)])
        try await env.selectedTeamStore.upsert(SelectedTeam(raceId: 11, teamId: 4))
        let appModel = AppModel(env: env)
        await appModel.start()
        await waitUntil { appModel.selectedTeamState == .present(self.team(id: 4, raceId: 11)) }

        let model = SettingsModel(env: env, appModel: appModel, raceId: 11, teamId: 4)
        model.resetTeam()

        await waitUntil { appModel.selectedTeamState == .none }
        #expect(appModel.selectedTeamState == .none)
    }

    // MARK: - Карта гонки

    /// Файл карты присутствует → `mapFileSizeLabel` форматирует размер («12 МБ»); отсутствует → `nil`.
    @Test func mapFileSizeLabel_presentAndAbsent() async throws {
        let transport = FakeTransport()
        // Файл на 12 МБ для гонки 7, для остальных — нет.
        let envWithFile = try AppEnvironment.inMemory(
            transport: transport.handle,
            mapFileSize: { raceId in raceId == 7 ? 12 * 1024 * 1024 : nil }
        )
        let appModel = AppModel(env: envWithFile)
        let present = SettingsModel(env: envWithFile, appModel: appModel, raceId: 7, teamId: 5)
        #expect(present.mapFileSizeLabel == "12 МБ")

        let absent = SettingsModel(env: envWithFile, appModel: appModel, raceId: 99, teamId: 5)
        #expect(absent.mapFileSizeLabel == nil)

        // Без выбранной гонки — тоже nil (замыкание даже не зовётся).
        let noRace = SettingsModel(env: envWithFile, appModel: appModel, raceId: nil, teamId: nil)
        #expect(noRace.mapFileSizeLabel == nil)
    }

    /// `mapFileSizeLabel` покрывает нецелые ветки `formatBytesRu` (русская запятичная дробь) и мелкие
    /// единицы — та самая причина, по которой это не `ByteCountFormatter` (локаленезависимый вывод).
    @Test func mapFileSizeLabel_formatBranches() async throws {
        let transport = FakeTransport()

        func label(bytes: Int64) throws -> String? {
            let env = try AppEnvironment.inMemory(
                transport: transport.handle,
                mapFileSize: { _ in bytes }
            )
            let appModel = AppModel(env: env)
            return SettingsModel(env: env, appModel: appModel, raceId: 7, teamId: 5).mapFileSizeLabel
        }

        // Дробная МБ → русская запятая: 1_610_612 / 1024 / 1024 ≈ 1.536 → «1,5 МБ».
        #expect(try label(bytes: 1_610_612) == "1,5 МБ")
        // Байты (< 1024) → целое, единица «Б».
        #expect(try label(bytes: 512) == "512 Б")
        // Дробные КБ → «1,5 КБ» (1536 / 1024 == 1.5).
        #expect(try label(bytes: 1536) == "1,5 КБ")
        // Целые КБ → без дроби.
        #expect(try label(bytes: 2048) == "2 КБ")
    }

    /// `deleteRaceMap()` дёргает замыкание графа с raceId скоупа и гасит лейбл (ряд становится disabled).
    @Test func deleteRaceMap_invokesClosureAndClearsLabel() async throws {
        let transport = FakeTransport()
        let deleted = DeletedRecorder()
        let env = try AppEnvironment.inMemory(
            transport: transport.handle,
            mapFileSize: { _ in 5 * 1024 * 1024 },
            deleteMapFile: { raceId in deleted.record(raceId) }
        )
        let appModel = AppModel(env: env)
        let model = SettingsModel(env: env, appModel: appModel, raceId: 7, teamId: 5)
        #expect(model.mapFileSizeLabel == "5 МБ")

        model.deleteRaceMap()

        await waitUntil { model.mapFileSizeLabel == nil }
        #expect(model.mapFileSizeLabel == nil)
        #expect(deleted.ids == [7])
    }

    // MARK: - Тема (прокси AppModel)

    /// `themeMode`-прокси читает/пишет прямо в `AppModel` (и, через него, в `ThemePreference`).
    @Test func themeMode_proxiesToAppModelAndPref() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        let appModel = AppModel(env: env)
        let model = SettingsModel(env: env, appModel: appModel, raceId: 7, teamId: 5)

        #expect(model.themeMode == appModel.themeMode)
        model.themeMode = .dark
        #expect(appModel.themeMode == .dark)
        #expect(env.themePreference.mode == .dark)
    }
}
