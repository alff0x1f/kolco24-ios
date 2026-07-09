//
//  TeamModelTests.swift
//  kolco24Tests
//
//  Тесты `TeamModel` — Android-зеркала нет (в Android состояние вкладки живёт в composable), пишутся
//  с нуля поверх РЕАЛЬНЫХ store'ов над `AppDatabase.makeInMemory()` (конвенция этапа 2). Сеть не
//  участвует — таблица `member_chip_bindings` локальная. Проверяем: derived `boundCount`/`allBound`
//  от записей стора, реакцию на upsert/deleteSlot (observation), rebind при смене команды, разрешение
//  категории и **stale-guard** (привязки команды A не видны после rebind на B до её эмиссии).
//
//  observation эмитит асинхронно — состояние ждём поллингом с таймаутом.
//

import Foundation
import Testing
@testable import kolco24

@MainActor
struct TeamModelTests {

    // MARK: - Фикстуры

    private func binding(team: Int, num: Int, uid: String = "AA", pnum: Int) -> MemberChipBinding {
        MemberChipBinding(teamId: team, numberInTeam: num, nfcUid: uid, participantNumber: pnum)
    }

    private func members(_ nums: [Int]) -> [TeamMemberItem] {
        nums.map { TeamMemberItem(name: "Участник \($0)", numberInTeam: $0) }
    }

    private func team(id: Int, raceId: Int, categoryId: Int? = nil) -> Team {
        Team(
            id: id, raceId: raceId, teamname: "Команда", startNumber: "1", categoryId: categoryId,
            ucount: 2, paidPeople: 2, startTime: 0, finishTime: 0,
            members: members([1, 2])
        )
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

    // MARK: - boundCount / allBound

    @Test func boundCount_countsOnlyCurrentRosterSlots() async throws {
        let env = try makeEnv()
        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 1, pnum: 100))
        // Устаревшая привязка слота, которого нет в ростере (3) — не должна засчитываться.
        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 3, uid: "BB", pnum: 200))
        let model = TeamModel(env: env)

        model.rebind(teamId: 5)
        await waitUntil { model.bindings.count == 2 }

        let roster = members([1, 2])
        #expect(model.boundCount(members: roster) == 1)
        #expect(model.allBound(members: roster, total: 2) == false)
    }

    // MARK: - Реакция на upsert / deleteSlot

    @Test func reactsToUpsertThenDeleteSlot() async throws {
        let env = try makeEnv()
        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 1, pnum: 100))
        let model = TeamModel(env: env)
        let roster = members([1, 2])

        model.rebind(teamId: 5)
        await waitUntil { model.boundCount(members: roster) == 1 }
        #expect(model.allBound(members: roster, total: 2) == false)

        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 2, uid: "BB", pnum: 200))
        await waitUntil { model.boundCount(members: roster) == 2 }
        #expect(model.allBound(members: roster, total: 2) == true)

        try await env.memberChipBindingStore.deleteSlot(teamId: 5, numberInTeam: 1)
        await waitUntil { model.boundCount(members: roster) == 1 }
        #expect(model.binding(for: 1) == nil)
        #expect(model.binding(for: 2)?.participantNumber == 200)
    }

    // MARK: - unbind (deleteSlot через модель)

    @Test func unbind_removesBinding() async throws {
        let env = try makeEnv()
        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 1, pnum: 100))
        let model = TeamModel(env: env)

        model.rebind(teamId: 5)
        await waitUntil { model.bindings.count == 1 }

        await model.unbind(teamId: 5, numberInTeam: 1)
        await waitUntil { model.bindings.isEmpty }
        #expect(model.binding(for: 1) == nil)
    }

    // MARK: - rebind при смене команды

    @Test func rebind_switchesToOtherTeamBindings() async throws {
        let env = try makeEnv()
        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 1, pnum: 100))
        try await env.memberChipBindingStore.upsert(binding(team: 6, num: 1, uid: "BB", pnum: 300))
        let model = TeamModel(env: env)

        model.rebind(teamId: 5)
        await waitUntil { model.binding(for: 1)?.participantNumber == 100 }

        model.rebind(teamId: 6)
        await waitUntil { model.binding(for: 1)?.participantNumber == 300 }
        #expect(model.bindings.count == 1)
    }

    // MARK: - Stale-guard

    @Test func rebind_clearsPreviousTeamBindingsSynchronously() async throws {
        let env = try makeEnv()
        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 1, pnum: 100))
        let model = TeamModel(env: env)

        model.rebind(teamId: 5)
        await waitUntil { !model.bindings.isEmpty }

        // Смена команды очищает привязки прежней синхронно (до первой эмиссии новой).
        model.rebind(teamId: 6)
        #expect(model.bindings.isEmpty)
    }

    // MARK: - Категория гонки

    @Test func category_resolvedFromRaceCategories() async throws {
        let env = try makeEnv()
        try await env.teamStore.insertCategories([
            kolco24.Category(id: 100, raceId: 3, code: "A", shortName: "12ч", name: "12 часов", sortOrder: 1),
        ])
        let model = TeamModel(env: env)
        let t = team(id: 10, raceId: 3, categoryId: 100)

        model.rebind(teamId: 10, raceId: 3)
        await waitUntil { !model.categories.isEmpty }

        #expect(model.category(for: t)?.id == 100)
        #expect(model.category(for: team(id: 11, raceId: 3, categoryId: nil)) == nil)
    }

    // MARK: - nil-команда снимает наблюдение

    @Test func rebindNil_clearsBindings() async throws {
        let env = try makeEnv()
        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 1, pnum: 100))
        let model = TeamModel(env: env)

        model.rebind(teamId: 5)
        await waitUntil { !model.bindings.isEmpty }

        model.rebind(teamId: nil)
        #expect(model.bindings.isEmpty)
    }
}
