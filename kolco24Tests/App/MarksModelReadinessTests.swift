//
//  MarksModelReadinessTests.swift
//  kolco24Tests
//
//  Тесты сборки чек-листа готовности в `MarksModel` — Kotlin-источника нет (iOS-only экран).
//  Чистая табличная логика статусов покрыта `ReadinessChecklistTests`; здесь проверяется ровно то,
//  чего таблица дать не может: чтение `mapUrl` из РЕАЛЬНОЙ БД (`AppDatabase.makeInMemory()`,
//  конвенция — БД не фейкаем), stale-guard при `rebind` на другую гонку, синхронный опрос устройства
//  (`refreshDeviceState`) и перечитывание файла подложки БЕЗ `rebind` (возврат с вкладки «Карта»).
//  Сюда же переехали интеграционные случаи снятой лестницы `MarksEmpty` («нет команды», «привязаны
//  не все чипы», «подавление до первой эмиссии») — переписанные на `readiness(team:members:clock:)`.
//
//  observation/one-shot чтения асинхронные — состояние ждём поллингом с таймаутом.
//

import Foundation
import Testing
@testable import kolco24

@MainActor
struct MarksModelReadinessTests {

    // MARK: - Фикстуры

    private func race(id: Int, mapUrl: String?) -> Race {
        Race(id: id, name: "Кольцо \(id)", slug: "k\(id)", date: "2026-09-19",
             place: "Лес", regStatus: "open", mapUrl: mapUrl)
    }

    private func team(id: Int, race: Int, name: String) -> Team {
        Team(id: id, raceId: race, teamname: name, startNumber: nil, categoryId: nil,
             ucount: 2, paidPeople: 2, startTime: 0, finishTime: 0, members: [])
    }

    private func members(_ nums: [Int]) -> [TeamMemberItem] {
        nums.map { TeamMemberItem(name: "Участник \($0)", numberInTeam: $0) }
    }

    private func binding(team: Int, num: Int, uid: String = "AA", pnum: Int) -> MemberChipBinding {
        MemberChipBinding(teamId: team, numberInTeam: num, nfcUid: uid, participantNumber: pnum)
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func item(_ items: [ReadinessItem], _ id: ReadinessItemId) -> ReadinessItem? {
        items.first { $0.id == id }
    }

    // MARK: - Доступность подложки (mapUrl из БД + файл с диска)

    @Test func mapReadiness_urlWithoutFileIsMissing() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle,
                                             mapFileExists: { _ in false })
        try await env.raceStore.insertAll([race(id: 7, mapUrl: "https://example.org/7.mbtiles")])

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.mapReadiness == .missing }

        #expect(model.mapReadiness == .missing)
        let map = item(model.readiness(team: nil, members: [], clock: .ok), .map)
        #expect(map?.status == .warning)
        #expect(map?.action == .openMap)
    }

    @Test func mapReadiness_urlWithFileIsReady() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle,
                                             mapFileExists: { $0 == 7 })
        try await env.raceStore.insertAll([race(id: 7, mapUrl: "https://example.org/7.mbtiles")])

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.mapReadiness == .ready }

        #expect(model.mapReadiness == .ready)
        #expect(item(model.readiness(team: nil, members: [], clock: .ok), .map)?.status == .done)
    }

    /// Гонка без подложки: пункт карты не просто `warning`, а отсутствует в массиве — иначе чек-лист
    /// был бы вечно неполным там, где скачивать нечего.
    @Test func mapReadiness_raceWithoutUrlHidesItem() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle,
                                             mapFileExists: { _ in true })
        try await env.raceStore.insertAll([race(id: 7, mapUrl: nil)])

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.marksLoading == false }
        model.refreshDeviceState()

        #expect(model.mapReadiness == .notApplicable)
        #expect(item(model.readiness(team: nil, members: [], clock: .ok), .map) == nil)
    }

    // MARK: - Stale-guard: подложка прежней гонки не доживает до эмиссии новой

    @Test func rebind_resetsMapReadinessSynchronously() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle,
                                             mapFileExists: { _ in true })
        try await env.raceStore.insertAll([
            race(id: 7, mapUrl: "https://example.org/7.mbtiles"),
            race(id: 8, mapUrl: "https://example.org/8.mbtiles"),
        ])

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.mapReadiness == .ready }

        // Синхронно после rebind на другую гонку — сброс, до чтения её `mapUrl` из БД.
        model.rebind(teamId: 43, raceId: 8)
        #expect(model.mapReadiness == .notApplicable)
        #expect(item(model.readiness(team: nil, members: [], clock: .ok), .map) == nil)

        // Эмиссия новой гонки приходит позже и возвращает пункт.
        await waitUntil { model.mapReadiness == .ready }
        #expect(model.mapReadiness == .ready)
    }

    // MARK: - Опрос устройства

    /// Подменённые замыкания `env` попадают в опубликованные свойства, а те — в пункты чек-листа.
    @Test func refreshDeviceState_pollsEnvClosures() async throws {
        let env = try AppEnvironment.inMemory(
            transport: FakeTransport().handle,
            isReducedAccuracy: { true },
            locationAuthorization: { .denied },
            isLowPowerMode: { true }
        )
        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        model.refreshDeviceState()

        #expect(model.locationAuth == .denied)
        #expect(model.isReducedAccuracy == true)
        #expect(model.lowPowerMode == true)

        let items = model.readiness(team: team(id: 42, race: 7, name: "Ф-мажор"),
                                    members: members([1]), clock: .noSync)
        #expect(item(items, .location)?.status == .warning)
        #expect(item(items, .location)?.action == .openSettings)
        #expect(item(items, .power)?.status == .warning)
        #expect(item(items, .clock)?.status == .warning)
        #expect(item(items, .team)?.status == .done)
        #expect(item(items, .team)?.detail == "Ф-мажор")
        // Ни одного чипа не привязано — blocked.
        #expect(item(items, .chips)?.status == .blocked)
    }

    /// Возврат с вкладки «Карта» не меняет `scenePhase` и не перезапускает `rebind` (та же пара
    /// `(teamId, raceId)` — ранний выход), поэтому файл перечитывается именно в `refreshDeviceState`.
    @Test func refreshDeviceState_rereadsMapFileWithoutRebind() async throws {
        let exists = MutableFlag()
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle,
                                              mapFileExists: { _ in exists.value })
        try await env.raceStore.insertAll([race(id: 7, mapUrl: "https://example.org/7.mbtiles")])

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.mapReadiness == .missing }
        #expect(model.mapReadiness == .missing)

        exists.value = true
        model.rebind(teamId: 42, raceId: 7)   // ранний выход — состояние не меняется
        #expect(model.mapReadiness == .missing)

        model.refreshDeviceState()
        #expect(model.mapReadiness == .ready)
    }

    // MARK: - Команда и привязки (интеграционные случаи снятой лестницы `MarksEmpty`)

    /// Нет команды: загрузки нет вовсе, а `team` и `chips` — оба `blocked` (без команды отметка
    /// физически не сработает). У `chips` при этом нет действия — сначала нужно выбрать команду.
    @Test func readiness_noTeamBlocksTeamAndChips() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle)
        let model = MarksModel(env: env)

        model.rebind(teamId: nil, raceId: nil)
        #expect(model.marksLoading == false)

        let items = model.readiness(team: nil, members: [], clock: .ok)
        #expect(item(items, .team)?.status == .blocked)
        #expect(item(items, .team)?.action == .chooseTeam)
        #expect(item(items, .chips)?.status == .blocked)
        #expect(item(items, .chips)?.detail == "Сначала выберите команду")
        #expect(item(items, .chips)?.action == nil)
    }

    /// Привязки приезжают из РЕАЛЬНОЙ БД через observation: 1 из 2 → `blocked` с «1 из 2», после
    /// второй привязки → `done`. Пустой ростер тоже `done` (нечего привязывать).
    @Test func readiness_unboundChipsBlockUntilAllBound() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle)
        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 1, pnum: 100))

        let model = MarksModel(env: env)
        let roster = members([1, 2])
        model.rebind(teamId: 5, raceId: 7)
        await waitUntil { model.bindings.count == 1 && model.marksLoading == false }

        let squad = team(id: 5, race: 7, name: "Ф-мажор")
        #expect(model.boundCount(members: roster) == 1)
        var chips = item(model.readiness(team: squad, members: roster, clock: .ok), .chips)
        #expect(chips?.status == .blocked)
        #expect(chips?.detail == "1 из 2")
        #expect(chips?.action == .bindChips)

        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 2, uid: "BB", pnum: 200))
        await waitUntil { model.boundCount(members: roster) == 2 }

        chips = item(model.readiness(team: squad, members: roster, clock: .ok), .chips)
        #expect(chips?.status == .done)
        #expect(chips?.detail == "2 из 2")
        // Пустой ростер не блокируем — привязывать нечего.
        #expect(item(model.readiness(team: squad, members: [], clock: .ok), .chips)?.status == .done)
    }

    // MARK: - Подавление до первой эмиссии (marksLoading)

    /// Лестницу гасил её собственный флаг `loading`, теперь мигание подавляет сама вьюха — ветка
    /// `model.marksLoading == true` не рисует ничего. Модель обязана взводить флаг синхронно в
    /// `rebind` и снимать после первой эмиссии, иначе чек-лист моргнёт ложным «чипы не привязаны».
    @Test func marksLoadingSuppressesChecklistUntilFirstEmission() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle)
        try await env.memberChipBindingStore.upsert(binding(team: 42, num: 1, pnum: 100))

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        // Синхронно после rebind: команда есть, observation ещё не эмитил — вьюха молчит.
        #expect(model.marksLoading == true)
        #expect(model.bindings.isEmpty)

        await waitUntil { model.marksLoading == false && model.bindings.count == 1 }
        // Флаг снят — показываем уже настоящее состояние привязок, а не пустой снимок.
        let squad = team(id: 42, race: 7, name: "Ф-мажор")
        #expect(item(model.readiness(team: squad, members: members([1]), clock: .ok), .chips)?.status == .done)
        #expect(item(model.readiness(team: squad, members: members([1, 2]), clock: .ok), .chips)?.status == .blocked)
    }
}

/// Потокобезопасный флаг для `@Sendable`-замыкания `mapFileExists`.
private final class MutableFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}
