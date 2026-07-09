//
//  CheckpointStoreTests.swift
//  kolco24Tests
//
//  Зеркало `CheckpointDaoTest.kt` (4 кейса) поверх in-memory GRDB. Проверяет
//  `CheckpointStore.replaceAllForRace`-preserve-on-resync (вариант A): резинк
//  не должен снова залочить оффлайн-раскрытый КП. На Android это @Transaction
//  тело нельзя покрыть JVM-фейком — тут покрывается обычным unit'ом.
//

import GRDB
import Testing
@testable import kolco24

struct CheckpointStoreTests {

    private func makeStore() throws -> CheckpointStore {
        CheckpointStore(try AppDatabase.makeInMemory().writer)
    }

    private func locked(_ id: Int, raceId: Int = 1, number: Int? = nil) -> Checkpoint {
        Checkpoint(
            id: id,
            raceId: raceId,
            number: number ?? id,
            cost: nil,
            type: "kp",
            description: nil,
            locked: true,
            encIv: "iv\(id)",
            encCt: "ct\(id)"
        )
    }

    private func open(_ id: Int, raceId: Int = 1, number: Int? = nil, cost: Int = 10) -> Checkpoint {
        Checkpoint(
            id: id,
            raceId: raceId,
            number: number ?? id,
            cost: cost,
            type: "kp",
            description: "Открытый \(id)",
            locked: false
        )
    }

    @Test func reveal_thenResyncWithSameLockedPayload_keepsRevealedContent() async throws {
        let store = try makeStore()
        try await store.replaceAllForRace(raceId: 1, checkpoints: [locked(10), open(20)])

        // User unlocks CP 10 offline.
        try await store.reveal(id: 10, cost: 40, description: "Под мостом")

        // A 200 refresh re-sends CP 10 still locked (server never sees the plaintext).
        try await store.replaceAllForRace(raceId: 1, checkpoints: [locked(10), open(20)])

        let rows = Dictionary(uniqueKeysWithValues: try await store.revealedForRace(1).map { ($0.id, $0) })
        let cp10 = try #require(rows[10])
        #expect(cp10.cost == 40)
        #expect(cp10.description == "Под мостом")
        // reveal() clears locked; the enc envelope is retained for reference.
        #expect(cp10.locked == false)
        #expect(cp10.encIv == "iv10")
    }

    @Test func resync_doesNotRevealCheckpointsThatWereNeverUnlocked() async throws {
        let store = try makeStore()
        try await store.replaceAllForRace(raceId: 1, checkpoints: [locked(10), locked(11)])
        try await store.reveal(id: 10, cost: 40, description: "Под мостом")

        try await store.replaceAllForRace(raceId: 1, checkpoints: [locked(10), locked(11)])

        let revealed = try await store.revealedForRace(1).map(\.id)
        #expect(revealed == [10])
    }

    @Test func resync_openRowOverwritesCleanly() async throws {
        let store = try makeStore()
        try await store.replaceAllForRace(raceId: 1, checkpoints: [open(20, cost: 10)])
        // Server changes the open CP's cost — the fresh value wins (no stale preserve for open rows).
        try await store.replaceAllForRace(raceId: 1, checkpoints: [open(20, cost: 25)])

        let cp20 = try #require(try await store.revealedForRace(1).first { $0.id == 20 })
        #expect(cp20.cost == 25)
        #expect(cp20.locked == false)
    }

    @Test func resync_droppingACheckpoint_removesIt() async throws {
        let store = try makeStore()
        try await store.replaceAllForRace(raceId: 1, checkpoints: [open(20), open(21)])
        try await store.replaceAllForRace(raceId: 1, checkpoints: [open(20)])

        let ids = try await store.revealedForRace(1).map(\.id)
        #expect(ids == [20])
        #expect(try await store.revealedForRace(1).first { $0.id == 21 } == nil)
    }
}
