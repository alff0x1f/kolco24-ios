//
//  MarksModelTests.swift
//  kolco24Tests
//
//  Тесты `MarksModel` — Android-зеркала нет (в Android состояние вкладки живёт в composable), пишутся
//  с нуля поверх РЕАЛЬНЫХ store'ов над `AppDatabase.makeInMemory()` (конвенция этапа 2). Сеть не
//  участвует — derived считаются из локальных строк (взятия/КП/агрегаты/привязки). Проверяем:
//  тайлы/метрики от засеянных marks+checkpoints (живая цена и фолбэк на снимок, полные/неполные
//  взятия), нотис hidden-taken при locked, лестницу empty-состояний (нет команды / не привязаны /
//  готов), подавление до первой эмиссии (`marksLoading`) и **stale-guard** (взятия команды A не
//  засчитаны команде B после rebind до её эмиссии — порт `safeMarks`).
//
//  observation эмитит асинхронно — состояние ждём поллингом с таймаутом.
//

import Foundation
import Testing
@testable import kolco24

@MainActor
struct MarksModelTests {

    // MARK: - Фикстуры

    private func openCP(id: Int, race: Int, number: Int, cost: Int, color: String = "") -> Checkpoint {
        Checkpoint(id: id, raceId: race, number: number, cost: cost, type: "cp",
                   description: "КП \(number)", locked: false, color: color)
    }

    private func lockedCP(id: Int, race: Int, number: Int) -> Checkpoint {
        Checkpoint(id: id, raceId: race, number: number, cost: nil, type: "cp",
                   description: nil, locked: true, encIv: "iv", encCt: "ct")
    }

    private func mark(
        id: String, race: Int, team: Int, cp: Int, number: Int, cost: Int,
        method: String = "nfc", complete: Bool = true, takenAt: Int64 = 0
    ) -> Mark {
        Mark(id: id, raceId: race, teamId: team, checkpointId: cp, checkpointNumber: number,
             cost: cost, method: method, cpUid: "UID\(cp)", cpCode: "K24", present: [1],
             expectedCount: 1, complete: complete, takenAt: takenAt, updatedAt: takenAt)
    }

    private func binding(team: Int, num: Int, uid: String = "AA", pnum: Int) -> MemberChipBinding {
        MemberChipBinding(teamId: team, numberInTeam: num, nfcUid: uid, participantNumber: pnum)
    }

    private func members(_ nums: [Int]) -> [TeamMemberItem] {
        nums.map { TeamMemberItem(name: "Участник \($0)", numberInTeam: $0) }
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

    // MARK: - Метрики: живая цена, фолбэк на снимок, технические/неполные взятия

    @Test func metricsUseLiveCostWithSnapshotFallback() async throws {
        let env = try makeEnv()
        try await env.checkpointStore.insertCheckpoints([
            openCP(id: 1, race: 7, number: 1, cost: 5),   // живая цена 5 (снимок взятия ниже — 2)
            openCP(id: 2, race: 7, number: 2, cost: 0),   // технический (cost 0) — не в ВЗЯТО
            lockedCP(id: 3, race: 7, number: 3),          // locked (cost nil → фолбэк на снимок 0)
        ])
        try await env.legendMetaStore.upsert(LegendMeta(raceId: 7, totalCost: 20, scoringCount: 3))
        try await env.markStore.upsert(mark(id: "m1", race: 7, team: 42, cp: 1, number: 1, cost: 2))
        try await env.markStore.upsert(mark(id: "m2", race: 7, team: 42, cp: 2, number: 2, cost: 0))
        try await env.markStore.upsert(mark(id: "m3", race: 7, team: 42, cp: 3, number: 3, cost: 0))

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.checkpoints.count == 3 && model.marks.count == 3 && model.legendMeta != nil }

        #expect(model.takenKp == 1)          // только КП1 (живая цена 5 > 0); КП2 технический, КП3 фолбэк 0
        #expect(model.takenScore == 5)       // 5 (живая) + 0 + 0
        #expect(model.totalKp == 3)          // scoring_count из legend_meta
        #expect(model.totalCost == 20)       // total_cost из legend_meta
    }

    // MARK: - Тайлы: один на complete-взятие, oldest-first, живая цена

    @Test func tilesOldestFirstWithLiveCost() async throws {
        let env = try makeEnv()
        try await env.checkpointStore.insertCheckpoints([
            openCP(id: 1, race: 7, number: 1, cost: 5),
            openCP(id: 2, race: 7, number: 2, cost: 3),
        ])
        // newest-first в сторе; неполное взятие не тайлится.
        try await env.markStore.upsert(mark(id: "new", race: 7, team: 42, cp: 2, number: 2, cost: 1, takenAt: 3_000))
        try await env.markStore.upsert(mark(id: "old", race: 7, team: 42, cp: 1, number: 1, cost: 1, takenAt: 2_000))
        try await env.markStore.upsert(mark(id: "part", race: 7, team: 42, cp: 1, number: 9, cost: 1, complete: false, takenAt: 4_000))

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.checkpoints.count == 2 && model.marks.count == 3 }

        let tiles = model.tiles
        #expect(tiles.count == 2)                       // неполное отброшено
        #expect(tiles.map(\.number) == ["01", "02"])    // oldest-first
        #expect(tiles[0].cost == 5)                     // живая цена КП1 (не снимок 1)
        #expect(tiles[1].cost == 3)                     // живая цена КП2
    }

    // MARK: - Фолбэк на снимок для КП, отсутствующего в легенде

    @Test func tileCostFallsBackToSnapshotForCheckpointAbsentFromLegend() async throws {
        let env = try makeEnv()
        // Гонка есть, но КП 9 в легенде нет (снят организатором) — цена берётся из снимка взятия.
        try await env.markStore.upsert(mark(id: "m9", race: 7, team: 42, cp: 9, number: 9, cost: 4))

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.marks.count == 1 }

        #expect(model.tiles.first?.cost == 4)
        #expect(model.takenScore == 4)
    }

    // MARK: - Нотис hidden-taken (locked-КП взяты)

    @Test func hiddenTakenTokensForLockedTaken() async throws {
        let env = try makeEnv()
        try await env.checkpointStore.insertCheckpoints([
            lockedCP(id: 3, race: 7, number: 3),
            openCP(id: 1, race: 7, number: 1, cost: 5),
        ])
        try await env.markStore.upsert(mark(id: "m1", race: 7, team: 42, cp: 1, number: 1, cost: 5, takenAt: 2_000))
        try await env.markStore.upsert(mark(id: "m3", race: 7, team: 42, cp: 3, number: 3, cost: 0, method: "photo", takenAt: 1_000))

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.checkpoints.count == 2 && model.marks.count == 2 }

        #expect(model.hiddenTakenTokens == ["?-03"])   // взят locked КП3; открытый КП1 не в нотисе
    }

    // MARK: - Лестница empty-состояний

    @Test func emptyLadder_noTeamChoosesTeam() async throws {
        let env = try makeEnv()
        let model = MarksModel(env: env)

        model.rebind(teamId: nil, raceId: nil)
        // Нет команды → не грузим, сразу chooseTeam.
        #expect(model.marksLoading == false)
        #expect(model.emptyState(hasTeam: false, members: []) == .chooseTeam)
    }

    @Test func emptyLadder_unboundNudgesBindThenReady() async throws {
        let env = try makeEnv()
        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 1, pnum: 100))

        let model = MarksModel(env: env)
        let roster = members([1, 2])
        model.rebind(teamId: 5, raceId: 7)
        await waitUntil { model.bindings.count == 1 && model.marksLoading == false }

        // 1 из 2 с чипом → нудж привязки.
        #expect(model.boundCount(members: roster) == 1)
        #expect(model.emptyState(hasTeam: true, members: roster) == .bindChips)

        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 2, uid: "BB", pnum: 200))
        await waitUntil { model.boundCount(members: roster) == 2 }
        // Все привязаны → готов.
        #expect(model.emptyState(hasTeam: true, members: roster) == .ready)
        // Пустой ростер тоже готов (не блокируем нудж-веткой).
        #expect(model.emptyState(hasTeam: true, members: []) == .ready)
    }

    // MARK: - Подавление до первой эмиссии (marksLoading)

    @Test func loadingSuppressesEmptyUntilFirstEmission() async throws {
        let env = try makeEnv()
        let model = MarksModel(env: env)

        model.rebind(teamId: 42, raceId: 7)
        // Синхронно после rebind: команда есть, observation ещё не эмитил → loading, empty подавлен.
        #expect(model.marksLoading == true)
        #expect(model.emptyState(hasTeam: true, members: members([1])) == .none)

        // После первой (пустой) эмиссии observation loading снимается — показываем реальное состояние
        // (пустой ростер → готов; с непривязанным участником было бы `.bindChips`).
        await waitUntil { model.marksLoading == false }
        #expect(model.emptyState(hasTeam: true, members: []) == .ready)
        #expect(model.emptyState(hasTeam: true, members: members([1])) == .bindChips)
    }

    // MARK: - Stale-guard (взятия команды A не засчитаны B до её эмиссии)

    @Test func rebind_clearsPreviousTeamRowsSynchronously() async throws {
        let env = try makeEnv()
        try await env.checkpointStore.insertCheckpoints([openCP(id: 1, race: 7, number: 1, cost: 5)])
        try await env.legendMetaStore.upsert(LegendMeta(raceId: 7, totalCost: 5, scoringCount: 1))
        try await env.markStore.upsert(mark(id: "m1", race: 7, team: 42, cp: 1, number: 1, cost: 5))

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { !model.marks.isEmpty && model.takenScore == 5 }

        // Смена команды/гонки очищает строки прежней синхронно (до первой эмиссии новой).
        model.rebind(teamId: 99, raceId: 8)
        #expect(model.marks.isEmpty)
        #expect(model.checkpoints.isEmpty)
        #expect(model.legendMeta == nil)
        #expect(model.tiles.isEmpty)
        #expect(model.takenKp == 0)
        #expect(model.takenScore == 0)
        #expect(model.totalCost == 0)
    }

    // MARK: - Реакция на новое взятие

    @Test func reactsToNewMark() async throws {
        let env = try makeEnv()
        try await env.checkpointStore.insertCheckpoints([openCP(id: 1, race: 7, number: 1, cost: 5)])
        try await env.legendMetaStore.upsert(LegendMeta(raceId: 7, totalCost: 5, scoringCount: 1))

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.checkpoints.count == 1 && model.marksLoading == false }
        #expect(model.tiles.isEmpty)

        try await env.markStore.upsert(mark(id: "m1", race: 7, team: 42, cp: 1, number: 1, cost: 5))
        await waitUntil { model.takenScore == 5 }
        #expect(model.tiles.count == 1)
        #expect(model.takenKp == 1)
    }
}
