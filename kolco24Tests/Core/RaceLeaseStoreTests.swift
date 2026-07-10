//
//  RaceLeaseStoreTests.swift
//  kolco24Tests
//
//  Зеркало `data/lease/RaceLeaseStoreTest.kt` 1:1: round-trip, атомарная одноключевая запись,
//  clear, pre-seeded read, отбраковка мусора (лишние/недостающие/нечисловые компоненты, пустая
//  строка).
//

import Testing
@testable import kolco24

struct RaceLeaseStoreTests {

    /// In-memory фейк инъецированного одноключевого store; `nil`-save удаляет ключ.
    private final class FakeStore {
        var map: [String: String]

        init(seed: [String: String] = [:]) {
            self.map = seed
        }

        func load(_ key: String) -> String? { map[key] }
        func save(_ key: String, _ value: String?) {
            if let value {
                map[key] = value
            } else {
                map.removeValue(forKey: key)
            }
        }
    }

    private func store(_ fake: FakeStore) -> RaceLeaseStore {
        RaceLeaseStore(load: fake.load, save: fake.save)
    }

    @Test
    func read_returnsNil_whenStoreEmpty() {
        let fake = FakeStore()
        #expect(store(fake).read() == nil)
    }

    @Test
    func write_thenRead_roundTrips() {
        let fake = FakeStore()
        let s = store(fake)
        let lease = RaceLease(raceId: 42, expiresAtMs: 1_700_000_000_000)

        s.write(lease)

        #expect(s.read() == lease)
    }

    @Test
    func write_storesSingleKey() {
        let fake = FakeStore()
        let s = store(fake)
        s.write(RaceLease(raceId: 1, expiresAtMs: 2))

        #expect(Set(fake.map.keys) == ["race_lease"])
    }

    @Test
    func clear_removesKey() {
        let fake = FakeStore()
        let s = store(fake)
        s.write(RaceLease(raceId: 1, expiresAtMs: 2))

        s.clear()

        #expect(s.read() == nil)
        #expect(fake.map["race_lease"] == nil)
    }

    @Test
    func read_reflectsPreSeededStore() {
        let fake = FakeStore(seed: ["race_lease": "42|1700000000000"])
        #expect(store(fake).read() == RaceLease(raceId: 42, expiresAtMs: 1_700_000_000_000))
    }

    @Test
    func read_returnsNil_whenTooFewFields() {
        let fake = FakeStore(seed: ["race_lease": "42"])
        #expect(store(fake).read() == nil)
    }

    @Test
    func read_returnsNil_whenTooManyFields() {
        let fake = FakeStore(seed: ["race_lease": "42|1700000000000|extra"])
        #expect(store(fake).read() == nil)
    }

    @Test
    func read_returnsNil_whenNonNumericRaceId() {
        let fake = FakeStore(seed: ["race_lease": "abc|1700000000000"])
        #expect(store(fake).read() == nil)
    }

    @Test
    func read_returnsNil_whenNonNumericExpiresAt() {
        let fake = FakeStore(seed: ["race_lease": "42|xyz"])
        #expect(store(fake).read() == nil)
    }

    @Test
    func read_returnsNil_whenEmptyString() {
        let fake = FakeStore(seed: ["race_lease": ""])
        #expect(store(fake).read() == nil)
    }
}
