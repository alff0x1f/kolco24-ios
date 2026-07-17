//
//  SimpleStoresTests.swift
//  kolco24Tests
//
//  Базовые тесты 8 простых store'ов этапа 2 (RaceStore, TeamStore,
//  SelectedTeamStore, TagStore, MemberTagStore, MemberChipBindingStore,
//  SyncMetaStore, LegendMetaStore) поверх in-memory GRDB.
//
//  БОНУС платформы: на Android эти 8 DAO реальным SQL не покрыты (их репо-тесты
//  ходят в фейки) — in-memory GRDB бесплатен, поэтому базовые тесты пишутся здесь
//  впервые (нет Kotlin-зеркала). Проверяем: скоупинг по raceId, сортировки (вкл.
//  `startNumber` с NULL/''/числами), upsert-семантику, `replaceAllForRace` над
//  двумя таблицами, атомарность `reassign`, `observeEtagsExist`.
//

import GRDB
import Testing
@testable import kolco24

struct SimpleStoresTests {

    // MARK: - Хелперы

    /// Первое значение observation'а (эмитится сразу на подписке).
    private func firstValue<T>(_ observation: AsyncValueObservation<T>) async throws -> T {
        for try await value in observation {
            return value
        }
        throw CancellationError()
    }

    private func makeDB() throws -> any DatabaseWriter {
        try AppDatabase.makeInMemory().writer
    }

    // MARK: - RaceStore

    @Test func raceReplaceAllWipesThenInserts() async throws {
        let db = try makeDB()
        let store = RaceStore(db)
        try await store.insertAll([race(1, date: "2026-01-01")])
        try await store.replaceAll([race(2, date: "2026-02-01"), race(3, date: "2026-03-01")])
        let rows = try await firstValue(store.observeRaces())
        #expect(rows.map(\.id) == [3, 2]) // date DESC
    }

    @Test func raceRoundTripsMapUrl() async throws {
        // Колонка mapUrl (миграция v2) переживает round-trip через store: значение и nil.
        let db = try makeDB()
        let store = RaceStore(db)
        try await store.replaceAll([
            Race(id: 1, name: "R1", slug: "r1", date: "2026-02-01",
                 place: "P", regStatus: "open", mapUrl: "https://cdn.test/1.mbtiles"),
            Race(id: 2, name: "R2", slug: "r2", date: "2026-01-01",
                 place: "P", regStatus: "open"), // mapUrl дефолтом nil
        ])
        let rows = try await firstValue(store.observeRaces())
        #expect(rows.first(where: { $0.id == 1 })?.mapUrl == "https://cdn.test/1.mbtiles")
        #expect(rows.first(where: { $0.id == 2 })?.mapUrl == nil)
    }

    @Test func raceObserveSortsByDateThenIdDesc() async throws {
        let db = try makeDB()
        let store = RaceStore(db)
        try await store.insertAll([
            race(1, date: "2026-01-01"),
            race(5, date: "2026-01-01"), // same date → id DESC
            race(2, date: "2026-05-01"),
        ])
        let rows = try await firstValue(store.observeRaces())
        #expect(rows.map(\.id) == [2, 5, 1])
    }

    // MARK: - TeamStore

    @Test func teamObserveSortsStartNumberNullEmptyNumbers() async throws {
        let db = try makeDB()
        let store = TeamStore(db)
        try await store.insertTeams([
            team(1, raceId: 10, startNumber: "10"),
            team(2, raceId: 10, startNumber: "2"),
            team(3, raceId: 10, startNumber: nil),
            team(4, raceId: 10, startNumber: ""),
            team(5, raceId: 10, startNumber: "5"),
        ])
        let rows = try await firstValue(store.observeTeamsForRace(10))
        // Non-empty numerically (2,5,10), then empty/null group by id (NULL before '' in SQLite).
        #expect(rows.map(\.id) == [2, 5, 1, 3, 4])
    }

    @Test func teamObserveScopedByRace() async throws {
        let db = try makeDB()
        let store = TeamStore(db)
        try await store.insertTeams([
            team(1, raceId: 10, startNumber: "1"),
            team(2, raceId: 20, startNumber: "1"),
        ])
        let rows = try await firstValue(store.observeTeamsForRace(10))
        #expect(rows.map(\.id) == [1])
    }

    @Test func categoryObserveSortsBySortOrderThenId() async throws {
        let db = try makeDB()
        let store = TeamStore(db)
        try await store.insertCategories([
            category(1, raceId: 10, sortOrder: 2),
            category(2, raceId: 10, sortOrder: 1),
            category(3, raceId: 10, sortOrder: 1),
        ])
        let rows = try await firstValue(store.observeCategoriesForRace(10))
        #expect(rows.map(\.id) == [2, 3, 1])
    }

    @Test func teamReplaceAllForRaceReplacesBothTablesScoped() async throws {
        let db = try makeDB()
        let store = TeamStore(db)
        // Seed race 10 and an untouched race 20.
        try await store.insertCategories([category(1, raceId: 10, sortOrder: 1), category(9, raceId: 20, sortOrder: 1)])
        try await store.insertTeams([team(1, raceId: 10, startNumber: "1"), team(9, raceId: 20, startNumber: "1")])

        try await store.replaceAllForRace(
            raceId: 10,
            categories: [category(2, raceId: 10, sortOrder: 1)],
            teams: [team(2, raceId: 10, startNumber: "1"), team(3, raceId: 10, startNumber: "2")]
        )

        let teams10 = try await firstValue(store.observeTeamsForRace(10))
        let cats10 = try await firstValue(store.observeCategoriesForRace(10))
        let teams20 = try await firstValue(store.observeTeamsForRace(20))
        let cats20 = try await firstValue(store.observeCategoriesForRace(20))
        #expect(teams10.map(\.id) == [2, 3])
        #expect(cats10.map(\.id) == [2])
        #expect(teams20.map(\.id) == [9]) // untouched
        #expect(cats20.map(\.id) == [9]) // untouched
    }

    @Test func teamObserveByIdReturnsNilWhenMissing() async throws {
        let db = try makeDB()
        let store = TeamStore(db)
        try await store.insertTeams([team(1, raceId: 10, startNumber: "1")])
        #expect(try await firstValue(store.observeTeamById(1))?.id == 1)
        #expect(try await firstValue(store.observeTeamById(999)) == nil)
    }

    // MARK: - SelectedTeamStore

    @Test func selectedTeamUpsertKeepsSingleRow() async throws {
        let db = try makeDB()
        let store = SelectedTeamStore(db)
        try await store.upsert(SelectedTeam(raceId: 10, teamId: 100))
        try await store.upsert(SelectedTeam(raceId: 20, teamId: 200))
        let row = try await firstValue(store.observe())
        #expect(row == SelectedTeam(id: 1, raceId: 20, teamId: 200))
    }

    @Test func selectedTeamClear() async throws {
        let db = try makeDB()
        let store = SelectedTeamStore(db)
        try await store.upsert(SelectedTeam(raceId: 10, teamId: 100))
        try await store.clear()
        #expect(try await firstValue(store.observe()) == nil)
    }

    // MARK: - TagStore

    @Test func tagGetByBidScopedByRace() async throws {
        let db = try makeDB()
        let store = TagStore(db)
        try await store.insertTags([
            Tag(raceId: 10, bid: "aa", checkpointId: 1, checkMethod: "nfc"),
            Tag(raceId: 20, bid: "aa", checkpointId: 2, checkMethod: "nfc"),
        ])
        #expect(try await store.getByBid(bid: "aa", raceId: 10)?.checkpointId == 1)
        #expect(try await store.getByBid(bid: "aa", raceId: 20)?.checkpointId == 2)
        #expect(try await store.getByBid(bid: "zz", raceId: 10) == nil)
    }

    @Test func tagObserveSortsByCheckpointThenBid() async throws {
        let db = try makeDB()
        let store = TagStore(db)
        try await store.insertTags([
            Tag(raceId: 10, bid: "bb", checkpointId: 2, checkMethod: "nfc"),
            Tag(raceId: 10, bid: "aa", checkpointId: 2, checkMethod: "nfc"),
            Tag(raceId: 10, bid: "cc", checkpointId: 1, checkMethod: "nfc"),
        ])
        let rows = try await firstValue(store.observeTagsForRace(10))
        #expect(rows.map(\.bid) == ["cc", "aa", "bb"])
    }

    @Test func tagReplaceAllForRaceScoped() async throws {
        let db = try makeDB()
        let store = TagStore(db)
        try await store.insertTags([
            Tag(raceId: 10, bid: "aa", checkpointId: 1, checkMethod: "nfc"),
            Tag(raceId: 20, bid: "aa", checkpointId: 9, checkMethod: "nfc"),
        ])
        try await store.replaceAllForRace(raceId: 10, tags: [Tag(raceId: 10, bid: "xx", checkpointId: 2, checkMethod: "nfc")])
        #expect(try await firstValue(store.observeTagsForRace(10)).map(\.bid) == ["xx"])
        #expect(try await firstValue(store.observeTagsForRace(20)).map(\.bid) == ["aa"]) // untouched
    }

    // MARK: - MemberTagStore

    @Test func memberTagFindByUidScoped() async throws {
        let db = try makeDB()
        let store = MemberTagStore(db)
        try await store.insertAll([
            MemberTag(raceId: 10, nfcUid: "u1", number: 5),
            MemberTag(raceId: 20, nfcUid: "u1", number: 7),
        ])
        #expect(try await store.findByUid(raceId: 10, nfcUid: "u1")?.number == 5)
        #expect(try await store.findByUid(raceId: 20, nfcUid: "u1")?.number == 7)
        #expect(try await store.findByUid(raceId: 10, nfcUid: "nope") == nil)
    }

    @Test func memberTagObserveSortsByNumberThenUid() async throws {
        let db = try makeDB()
        let store = MemberTagStore(db)
        try await store.insertAll([
            MemberTag(raceId: 10, nfcUid: "b", number: 2),
            MemberTag(raceId: 10, nfcUid: "a", number: 2),
            MemberTag(raceId: 10, nfcUid: "z", number: 1),
        ])
        let rows = try await firstValue(store.observeForRace(10))
        #expect(rows.map(\.nfcUid) == ["z", "a", "b"])
    }

    @Test func memberTagReplaceAllForRaceScoped() async throws {
        let db = try makeDB()
        let store = MemberTagStore(db)
        try await store.insertAll([
            MemberTag(raceId: 10, nfcUid: "u1", number: 1),
            MemberTag(raceId: 20, nfcUid: "u9", number: 9),
        ])
        try await store.replaceAllForRace(raceId: 10, tags: [MemberTag(raceId: 10, nfcUid: "u2", number: 2)])
        #expect(try await firstValue(store.observeForRace(10)).map(\.nfcUid) == ["u2"])
        #expect(try await firstValue(store.observeForRace(20)).map(\.nfcUid) == ["u9"]) // untouched
    }

    // MARK: - MemberChipBindingStore

    @Test func chipBindingUpsertReplacesSlot() async throws {
        let db = try makeDB()
        let store = MemberChipBindingStore(db)
        try await store.upsert(MemberChipBinding(teamId: 1, numberInTeam: 1, nfcUid: "u1", participantNumber: 10))
        try await store.upsert(MemberChipBinding(teamId: 1, numberInTeam: 1, nfcUid: "u2", participantNumber: 20))
        let rows = try await firstValue(store.observeForTeam(1))
        #expect(rows == [MemberChipBinding(teamId: 1, numberInTeam: 1, nfcUid: "u2", participantNumber: 20)])
    }

    @Test func chipBindingReassignIsAtomicMove() async throws {
        let db = try makeDB()
        let store = MemberChipBindingStore(db)
        // Chip u1 initially on slot (1,1).
        try await store.upsert(MemberChipBinding(teamId: 1, numberInTeam: 1, nfcUid: "u1", participantNumber: 10))
        // Reassign the same chip u1 to slot (1,2): old slot must be gone, chip on exactly one slot.
        try await store.reassign(MemberChipBinding(teamId: 1, numberInTeam: 2, nfcUid: "u1", participantNumber: 10))
        let rows = try await firstValue(store.observeForTeam(1))
        #expect(rows == [MemberChipBinding(teamId: 1, numberInTeam: 2, nfcUid: "u1", participantNumber: 10)])
        #expect(try await store.findByUid("u1")?.numberInTeam == 2)
    }

    @Test func chipBindingDeleteSlotAndByUid() async throws {
        let db = try makeDB()
        let store = MemberChipBindingStore(db)
        try await store.upsert(MemberChipBinding(teamId: 1, numberInTeam: 1, nfcUid: "u1", participantNumber: 10))
        try await store.upsert(MemberChipBinding(teamId: 1, numberInTeam: 2, nfcUid: "u2", participantNumber: 20))
        try await store.deleteSlot(teamId: 1, numberInTeam: 1)
        #expect(try await store.findByUid("u1") == nil)
        try await store.deleteByUid("u2")
        #expect(try await firstValue(store.observeForTeam(1)).isEmpty)
    }

    @Test func chipBindingObserveScopedByTeam() async throws {
        let db = try makeDB()
        let store = MemberChipBindingStore(db)
        try await store.upsert(MemberChipBinding(teamId: 1, numberInTeam: 2, nfcUid: "u2", participantNumber: 20))
        try await store.upsert(MemberChipBinding(teamId: 1, numberInTeam: 1, nfcUid: "u1", participantNumber: 10))
        try await store.upsert(MemberChipBinding(teamId: 2, numberInTeam: 1, nfcUid: "u9", participantNumber: 90))
        let rows = try await firstValue(store.observeForTeam(1))
        #expect(rows.map(\.numberInTeam) == [1, 2]) // ORDER BY numberInTeam
    }

    // MARK: - SyncMetaStore

    @Test func syncMetaUpsertAndGetEtag() async throws {
        let db = try makeDB()
        let store = SyncMetaStore(db)
        try await store.upsert(SyncMeta(origin: "o1", resource: "races", etag: "\"v1\""))
        try await store.upsert(SyncMeta(origin: "o1", resource: "races", etag: "\"v2\"")) // upsert replaces
        #expect(try await store.getEtag(origin: "o1", resource: "races") == "\"v2\"")
        #expect(try await store.getEtag(origin: "o2", resource: "races") == nil) // origin-scoped
    }

    @Test func syncMetaDeleteEtag() async throws {
        let db = try makeDB()
        let store = SyncMetaStore(db)
        try await store.upsert(SyncMeta(origin: "o1", resource: "races", etag: "\"v1\""))
        try await store.deleteEtag(origin: "o1", resource: "races")
        #expect(try await store.getEtag(origin: "o1", resource: "races") == nil)
    }

    @Test func syncMetaObserveEtagsExist() async throws {
        let db = try makeDB()
        let store = SyncMetaStore(db)
        #expect(try await firstValue(store.observeEtagsExist(origin: "o1", resource1: "teams", resource2: "legend")) == false)
        try await store.upsert(SyncMeta(origin: "o1", resource: "legend", etag: "\"e\""))
        #expect(try await firstValue(store.observeEtagsExist(origin: "o1", resource1: "teams", resource2: "legend")) == true)
        // Other origin: still absent.
        #expect(try await firstValue(store.observeEtagsExist(origin: "o2", resource1: "teams", resource2: "legend")) == false)
    }

    // MARK: - LegendMetaStore

    @Test func legendMetaUpsertScopedByRace() async throws {
        let db = try makeDB()
        let store = LegendMetaStore(db)
        try await store.upsert(LegendMeta(raceId: 10, totalCost: 100, scoringCount: 5))
        try await store.upsert(LegendMeta(raceId: 10, totalCost: 200, scoringCount: 8)) // upsert replaces
        try await store.upsert(LegendMeta(raceId: 20, totalCost: 50, scoringCount: 2))
        #expect(try await firstValue(store.observeForRace(10)) == LegendMeta(raceId: 10, totalCost: 200, scoringCount: 8))
        #expect(try await firstValue(store.observeForRace(20)) == LegendMeta(raceId: 20, totalCost: 50, scoringCount: 2))
        #expect(try await firstValue(store.observeForRace(999)) == nil)
    }

    // MARK: - Фабрики строк

    private func race(_ id: Int, date: String) -> Race {
        Race(id: id, name: "R\(id)", slug: "r\(id)", date: date, place: "P", regStatus: "open")
    }

    private func team(_ id: Int, raceId: Int, startNumber: String?) -> Team {
        Team(
            id: id, raceId: raceId, teamname: "T\(id)", startNumber: startNumber,
            categoryId: nil, ucount: 0, paidPeople: 0, startTime: 0, finishTime: 0, members: []
        )
    }

    private func category(_ id: Int, raceId: Int, sortOrder: Int) -> Category {
        Category(id: id, raceId: raceId, code: "C\(id)", shortName: "c\(id)", name: "Cat\(id)", sortOrder: sortOrder)
    }
}
