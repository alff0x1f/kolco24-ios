//
//  MarksModelReadinessTests.swift
//  kolco24Tests
//
//  Тесты сборки чек-листа готовности в `MarksModel` — Kotlin-источника нет (iOS-only экран).
//  Чистая табличная логика статусов покрыта `ReadinessChecklistTests`; здесь проверяется ровно то,
//  чего таблица дать не может: чтение `mapUrl` из РЕАЛЬНОЙ БД (`AppDatabase.makeInMemory()`,
//  конвенция — БД не фейкаем), stale-guard при `rebind` на другую гонку, синхронный опрос устройства
//  (`refreshDeviceState`) и перечитывание файла подложки БЕЗ `rebind` (возврат с вкладки «Карта»).
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
