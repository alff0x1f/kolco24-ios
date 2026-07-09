//
//  LegendModelTests.swift
//  kolco24Tests
//
//  Тесты `LegendModel` — Android-зеркала нет (в Android состояние вкладки живёт в composable), пишутся
//  с нуля поверх РЕАЛЬНЫХ store'ов над `AppDatabase.makeInMemory()` (конвенция этапа 2). Сеть не
//  участвует — derived считаются из локальных строк (КП/агрегаты/взятия). Проверяем: derived-значения
//  от засеянных строк (locked/open/taken), реакцию на reveal и на смену команды/гонки (observation),
//  и **stale-guard** (строки гонки A не участвуют в derived после rebind на B до её эмиссии).
//
//  observation эмитит асинхронно — состояние ждём поллингом с таймаутом.
//

import Foundation
import Testing
@testable import kolco24

@MainActor
struct LegendModelTests {

    // MARK: - Фикстуры

    private func openCP(id: Int, race: Int, number: Int, cost: Int, color: String = "") -> Checkpoint {
        Checkpoint(id: id, raceId: race, number: number, cost: cost, type: "cp",
                   description: "КП \(number)", locked: false, color: color)
    }

    private func lockedCP(id: Int, race: Int, number: Int) -> Checkpoint {
        Checkpoint(id: id, raceId: race, number: number, cost: nil, type: "cp",
                   description: nil, locked: true, encIv: "iv", encCt: "ct")
    }

    private func completeMark(id: String, race: Int, team: Int, cp: Int, cost: Int) -> Mark {
        Mark(id: id, raceId: race, teamId: team, checkpointId: cp, checkpointNumber: cp,
             cost: cost, method: "nfc", cpUid: "UID\(cp)", cpCode: "K24", present: [1],
             expectedCount: 1, complete: true, takenAt: 0, updatedAt: 0)
    }

    private func makeEnv() throws -> AppEnvironment {
        try AppEnvironment.inMemory(transport: FakeTransport().handle)
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Derived от засеянных строк

    @Test func derivedFromSeededRows() async throws {
        let env = try makeEnv()
        try await env.checkpointStore.insertCheckpoints([
            openCP(id: 1, race: 7, number: 1, cost: 0),   // технический КП (cost 0)
            openCP(id: 2, race: 7, number: 2, cost: 5),
            openCP(id: 3, race: 7, number: 3, cost: 3),
            lockedCP(id: 4, race: 7, number: 4),
        ])
        // total_cost включает скрытую цену locked-КП; scoring_count = число КП с cost>0 (incl. locked).
        try await env.legendMetaStore.upsert(LegendMeta(raceId: 7, totalCost: 20, scoringCount: 3))
        // Команда 42 взяла КП 2 (cost 5) и технический КП 1 (cost 0).
        try await env.markStore.upsert(completeMark(id: "m1", race: 7, team: 42, cp: 2, cost: 5))
        try await env.markStore.upsert(completeMark(id: "m2", race: 7, team: 42, cp: 1, cost: 0))

        let model = LegendModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.checkpoints.count == 4 && model.legendMeta != nil && !model.marks.isEmpty }

        #expect(model.totalCount == 4)
        #expect(model.takenIds == [1, 2])
        #expect(model.takenCount == 2)                 // оба взятых КП считаются в списке/чипах
        #expect(model.takenScoring == 1)               // только КП 2 (cost>0) идёт в scoring-числитель
        #expect(model.scoringCount == 3)
        #expect(model.takenScore == 5)                 // сумма известных цен взятых (КП1=0 + КП2=5)
        #expect(model.totalScore == 20)                // из legend_meta, не сумма строк
        #expect(model.lockedCount == 1)
        #expect(abs(model.progress - 0.25) < 0.0001)   // 5/20
    }

    // MARK: - Фильтр «только не взятые»

    @Test func visibleCheckpoints_filtersTaken() async throws {
        let env = try makeEnv()
        try await env.checkpointStore.insertCheckpoints([
            openCP(id: 1, race: 7, number: 1, cost: 5),
            openCP(id: 2, race: 7, number: 2, cost: 3),
        ])
        try await env.markStore.upsert(completeMark(id: "m1", race: 7, team: 42, cp: 1, cost: 5))

        let model = LegendModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.checkpoints.count == 2 && !model.marks.isEmpty }

        #expect(model.visibleCheckpoints(showOnlyOpen: false).map(\.id) == [1, 2])
        #expect(model.visibleCheckpoints(showOnlyOpen: true).map(\.id) == [2])
    }

    // MARK: - Реакция на reveal (locked → open)

    @Test func reactsToReveal() async throws {
        let env = try makeEnv()
        try await env.checkpointStore.insertCheckpoints([lockedCP(id: 4, race: 7, number: 4)])
        try await env.legendMetaStore.upsert(LegendMeta(raceId: 7, totalCost: 7, scoringCount: 1))

        let model = LegendModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.lockedCount == 1 }

        try await env.checkpointStore.reveal(id: 4, cost: 7, description: "Раскрытый КП")
        await waitUntil { model.lockedCount == 0 }
        #expect(model.checkpoints.first?.cost == 7)
        #expect(model.checkpoints.first?.locked == false)
    }

    // MARK: - Реакция на новое взятие

    @Test func reactsToNewMark() async throws {
        let env = try makeEnv()
        try await env.checkpointStore.insertCheckpoints([openCP(id: 1, race: 7, number: 1, cost: 5)])

        let model = LegendModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.checkpoints.count == 1 }
        #expect(model.takenIds.isEmpty)

        try await env.markStore.upsert(completeMark(id: "m1", race: 7, team: 42, cp: 1, cost: 5))
        await waitUntil { model.takenScore == 5 }
        #expect(model.takenIds == [1])
    }

    // MARK: - Смена команды/гонки

    @Test func rebind_switchesRaceAndTeam() async throws {
        let env = try makeEnv()
        try await env.checkpointStore.insertCheckpoints([
            openCP(id: 1, race: 7, number: 1, cost: 5),
            openCP(id: 2, race: 8, number: 1, cost: 4),
        ])
        try await env.markStore.upsert(completeMark(id: "m1", race: 7, team: 42, cp: 1, cost: 5))
        try await env.markStore.upsert(completeMark(id: "m2", race: 8, team: 99, cp: 2, cost: 4))

        let model = LegendModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.checkpoints.map(\.id) == [1] && model.takenIds == [1] }

        model.rebind(teamId: 99, raceId: 8)
        await waitUntil { model.checkpoints.map(\.id) == [2] && model.takenIds == [2] }
        #expect(model.takenScore == 4)
    }

    // MARK: - Stale-guard

    @Test func rebind_clearsPreviousRaceRowsSynchronously() async throws {
        let env = try makeEnv()
        try await env.checkpointStore.insertCheckpoints([openCP(id: 1, race: 7, number: 1, cost: 5)])
        try await env.markStore.upsert(completeMark(id: "m1", race: 7, team: 42, cp: 1, cost: 5))

        let model = LegendModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { !model.checkpoints.isEmpty && !model.marks.isEmpty }

        // Смена гонки/команды очищает строки прежней синхронно (до первой эмиссии новой).
        model.rebind(teamId: 99, raceId: 8)
        #expect(model.checkpoints.isEmpty)
        #expect(model.marks.isEmpty)
        #expect(model.legendMeta == nil)
        #expect(model.takenIds.isEmpty)
        #expect(model.takenScore == 0)
        #expect(model.progress == 0)
    }

    // MARK: - nil-выбор снимает наблюдение

    @Test func rebindNil_clearsRows() async throws {
        let env = try makeEnv()
        try await env.checkpointStore.insertCheckpoints([openCP(id: 1, race: 7, number: 1, cost: 5)])

        let model = LegendModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { !model.checkpoints.isEmpty }

        model.rebind(teamId: nil, raceId: nil)
        #expect(model.checkpoints.isEmpty)
    }
}
