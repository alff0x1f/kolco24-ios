//
//  MarksModelTests.swift
//  kolco24Tests
//
//  Тесты `MarksModel` — Android-зеркала нет (в Android состояние вкладки живёт в composable), пишутся
//  с нуля поверх РЕАЛЬНЫХ store'ов над `AppDatabase.makeInMemory()` (конвенция этапа 2). Сеть не
//  участвует — derived считаются из локальных строк (взятия/КП/агрегаты/привязки). Проверяем:
//  тайлы/метрики от засеянных marks+checkpoints (живая цена и фолбэк на снимок, полные/неполные
//  взятия), нотис hidden-taken при locked и **stale-guard** (взятия команды A не засчитаны команде B
//  после rebind до её эмиссии — порт `safeMarks`). Интеграционные случаи чек-листа готовности
//  (команда, привязки, подавление до первой эмиссии) живут в `MarksModelReadinessTests`.
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
        method: String = "nfc", complete: Bool = true, takenAt: Int64 = 0,
        checkMethod: String = "offline"
    ) -> Mark {
        Mark(id: id, raceId: race, teamId: team, checkpointId: cp, checkpointNumber: number,
             cost: cost, method: method, cpUid: "UID\(cp)", cpCode: "K24", present: [1],
             expectedCount: 1, complete: complete, takenAt: takenAt, updatedAt: takenAt,
             checkMethod: checkMethod)
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

    // MARK: - Фото-взятие: тайл с кадрами, сводка «КП по фото», лента лайтбокса

    @Test func photoMarkFeedsTileFramesAndReviewSummary() async throws {
        let env = try makeEnv()
        try await env.checkpointStore.insertCheckpoints([openCP(id: 1, race: 7, number: 5, cost: 4)])
        try await env.legendMetaStore.upsert(LegendMeta(raceId: 7, totalCost: 4, scoringCount: 1))
        // Фото-взятие: method="photo", два кадра в photoPath, chip-подтверждения нет → нотис показывается.
        let photoPaths = PhotoPaths.encode([
            "marks/p1/aaaaaaaa.jpg",
            "marks/p1/bbbbbbbb.jpg",
        ])
        try await env.markStore.upsert(Mark(
            id: "p1", raceId: 7, teamId: 42, checkpointId: 1, checkpointNumber: 5,
            cost: 0, method: "photo", cpUid: "", cpCode: "", present: [],
            expectedCount: 4, complete: true, photoPath: photoPaths, takenAt: 1_000, updatedAt: 1_000
        ))

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.checkpoints.count == 1 && model.marks.count == 1 }

        // Тайл — фото-вида с двумя кадрами.
        #expect(model.tiles.count == 1)
        let tile = try #require(model.tiles.first)
        #expect(tile.kind == .photo)
        #expect(tile.photoCount == 2)
        #expect(tile.photoPaths == ["marks/p1/aaaaaaaa.jpg", "marks/p1/bbbbbbbb.jpg"])

        // Лента лайтбокса — оба кадра в порядке сетки.
        #expect(model.lightboxPhotos.map(\.path) == ["marks/p1/aaaaaaaa.jpg", "marks/p1/bbbbbbbb.jpg"])

        // Сводка «КП по фото» непуста: 1 КП, живая цена 4 балла.
        let review = try #require(model.photoReview)
        #expect(review.count == 1)
        #expect(review.points == 4)          // живая цена КП5 (снимок взятия — 0)
        #expect(review.tokens == ["4-05"])
    }

    // MARK: - Неподтверждённое cloud-взятие: тайл есть, в метриках нет, в нотисе есть

    @Test func unconfirmedCloudTakeShowsTileButNotScoreUntilConfirmed() async throws {
        let env = try makeEnv()
        try await env.checkpointStore.insertCheckpoints([
            openCP(id: 1, race: 7, number: 1, cost: 5),
            openCP(id: 2, race: 7, number: 2, cost: 3),
        ])
        try await env.markStore.upsert(mark(id: "off", race: 7, team: 42, cp: 1, number: 1, cost: 5, takenAt: 1_000))
        try await env.markStore.upsert(mark(id: "cl", race: 7, team: 42, cp: 2, number: 2, cost: 3,
                                            takenAt: 2_000, checkMethod: "cloud"))

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.checkpoints.count == 2 && model.marks.count == 2 }

        #expect(model.tiles.map(\.number) == ["01", "02"])      // тайл неподтверждённого остаётся
        #expect(model.tiles.map(\.unconfirmed) == [false, true])
        #expect(model.takenKp == 1)                              // только offline КП1
        #expect(model.takenScore == 5)
        #expect(model.unconfirmedTokens == ["3-02"])             // живая цена КП2

        try await env.markStore.setConfirmedAt(id: "cl", at: 2_500)
        await waitUntil { model.takenScore == 8 }

        #expect(model.takenKp == 2)
        #expect(model.takenScore == 8)
        #expect(model.unconfirmedTokens.isEmpty)                 // нотис исчезает
        #expect(model.tiles.map(\.unconfirmed) == [false, false])
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

    // MARK: - КВ: категория команды → состояние «До КВ»

    private func typedCP(id: Int, race: Int, number: Int, type: String) -> Checkpoint {
        Checkpoint(id: id, raceId: race, number: number, cost: 0, type: type,
                   description: nil, locked: false)
    }

    private func team(id: Int, race: Int, categoryId: Int?) -> Team {
        Team(id: id, raceId: race, teamname: "T\(id)", categoryId: categoryId, ucount: 1,
             paidPeople: 1, startTime: 0, finishTime: 0, members: [])
    }

    @Test func controlState_runningFromCategoryControlTimeAndStartMark() async throws {
        let env = try makeEnv()
        try await env.teamStore.insertCategories([
            kolco24.Category(id: 3, raceId: 7, code: "24", shortName: "24ч", name: "24 часа",
                             sortOrder: 1, controlTime: 480),
        ])
        try await env.checkpointStore.insertCheckpoints([typedCP(id: 1, race: 7, number: 0, type: "start")])
        try await env.markStore.upsert(mark(id: "s", race: 7, team: 42, cp: 1, number: 0, cost: 0,
                                            takenAt: 1_000_000))

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { !model.categories.isEmpty && !model.checkpoints.isEmpty && !model.marks.isEmpty }

        let t = team(id: 42, race: 7, categoryId: 3)
        // 3 ч после старта: до КВ (8 ч) остаётся 5 ч.
        let now: Int64 = 1_000_000 + 3 * 3_600_000
        #expect(model.controlState(team: t, nowMs: now) == .running(remainingMs: 5 * 3_600_000))
    }

    @Test func controlState_unknownWithoutTeamOrCategory() async throws {
        let env = try makeEnv()
        try await env.teamStore.insertCategories([
            kolco24.Category(id: 3, raceId: 7, code: "24", shortName: "24ч", name: "24 часа",
                             sortOrder: 1, controlTime: 480),
        ])

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { !model.categories.isEmpty }

        #expect(model.controlState(team: team(id: 42, race: 7, categoryId: nil), nowMs: 0) == .unknown)
        #expect(model.controlState(team: nil, nowMs: 0) == .unknown)
        // categoryId указывает на незагруженную категорию → КВ 0 → `.unknown`.
        #expect(model.controlState(team: team(id: 42, race: 7, categoryId: 999), nowMs: 0) == .unknown)
        // Категория с КВ, старта нет → КВ показывается.
        #expect(model.controlState(team: team(id: 42, race: 7, categoryId: 3), nowMs: 0)
                == .notStarted(limitMs: 480 * 60_000))
    }

    @Test func rebind_clearsCategoriesSynchronously() async throws {
        let env = try makeEnv()
        try await env.teamStore.insertCategories([
            kolco24.Category(id: 3, raceId: 7, code: "24", shortName: "24ч", name: "24 часа",
                             sortOrder: 1, controlTime: 480),
            kolco24.Category(id: 5, raceId: 8, code: "12", shortName: "12ч", name: "12 часов",
                             sortOrder: 1, controlTime: 720),
        ])

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { !model.categories.isEmpty }
        #expect(model.categories.map(\.id) == [3])

        // Другая гонка: категории прежней очищаются синхронно, до эмиссии новой.
        model.rebind(teamId: 42, raceId: 8)
        #expect(model.categories.isEmpty)
        #expect(model.controlState(team: team(id: 42, race: 8, categoryId: 3), nowMs: 0) == .unknown)

        // После эмиссии — только категории новой гонки и её КВ.
        await waitUntil { !model.categories.isEmpty }
        #expect(model.categories.map(\.id) == [5])
        #expect(model.controlState(team: team(id: 42, race: 8, categoryId: 3), nowMs: 0) == .unknown)
        #expect(model.controlState(team: team(id: 42, race: 8, categoryId: 5), nowMs: 0)
                == .notStarted(limitMs: 720 * 60_000))
    }
}
