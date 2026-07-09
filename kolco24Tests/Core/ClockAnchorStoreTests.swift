//
//  ClockAnchorStoreTests.swift
//  kolco24Tests
//
//  Зеркало `data/time/ClockAnchorStoreTest.kt` 1:1: round-trip, атомарная одноключевая запись,
//  битые строки → nil, `bootCount` опционален (вкл. хвостовой-`|` nil-bootCount кейс — порт-ловушка).
//

import Testing
@testable import kolco24

struct ClockAnchorStoreTests {

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

    private func store(_ fake: FakeStore) -> ClockAnchorStore {
        ClockAnchorStore(load: fake.load, save: fake.save)
    }

    @Test
    func readReturnsNilWhenStoreEmpty() {
        let fake = FakeStore()
        #expect(store(fake).read() == nil)
    }

    @Test
    func writeThenReadRoundTripsWithBootCount() {
        let fake = FakeStore()
        let s = store(fake)
        let anchor = ClockAnchor(
            serverEpochMs: 1_700_000_000_000,
            anchorElapsedMs: 123_456,
            capturedWallMs: 1_700_000_000_500,
            bootCount: 7
        )

        s.write(anchor)

        #expect(s.read() == anchor)
    }

    @Test
    func writeThenReadRoundTripsWithNilBootCount() {
        let fake = FakeStore()
        let s = store(fake)
        let anchor = ClockAnchor(
            serverEpochMs: 1_700_000_000_000,
            anchorElapsedMs: 123_456,
            capturedWallMs: 1_700_000_000_500,
            bootCount: nil
        )

        s.write(anchor)

        #expect(s.read() == anchor)
    }

    @Test
    func writeStoresSingleKey() {
        // Инвариант атомарной записи (P1): персистится ровно один ключ, не четыре.
        let fake = FakeStore()
        store(fake).write(ClockAnchor(serverEpochMs: 1, anchorElapsedMs: 2, capturedWallMs: 3, bootCount: 4))

        #expect(Set(fake.map.keys) == ["anchor"])
    }

    @Test
    func clearRemovesKey() {
        let fake = FakeStore()
        let s = store(fake)
        s.write(ClockAnchor(serverEpochMs: 1, anchorElapsedMs: 2, capturedWallMs: 3, bootCount: 4))

        s.clear()

        #expect(s.read() == nil)
        #expect(fake.map["anchor"] == nil)
    }

    @Test
    func readReflectsPreSeededStore() {
        let fake = FakeStore(seed: ["anchor": "1700000000000|123456|1700000000500|7"])
        #expect(
            store(fake).read()
                == ClockAnchor(serverEpochMs: 1_700_000_000_000, anchorElapsedMs: 123_456, capturedWallMs: 1_700_000_000_500, bootCount: 7)
        )
    }

    @Test
    func readPreSeededEmptyBootSegmentIsNilBootCount() {
        // Порт-ловушка: хвостовой пустой сегмент (4 части) → bootCount == nil.
        let fake = FakeStore(seed: ["anchor": "1700000000000|123456|1700000000500|"])
        #expect(
            store(fake).read()
                == ClockAnchor(serverEpochMs: 1_700_000_000_000, anchorElapsedMs: 123_456, capturedWallMs: 1_700_000_000_500, bootCount: nil)
        )
    }

    @Test
    func readReturnsNilWhenTooFewFields() {
        let fake = FakeStore(seed: ["anchor": "1700000000000|123456|1700000000500"])
        #expect(store(fake).read() == nil)
    }

    @Test
    func readReturnsNilWhenTooManyFields() {
        let fake = FakeStore(seed: ["anchor": "1|2|3|4|5"])
        #expect(store(fake).read() == nil)
    }

    @Test
    func readReturnsNilWhenNonNumericLongSegment() {
        let fake = FakeStore(seed: ["anchor": "abc|123456|1700000000500|7"])
        #expect(store(fake).read() == nil)
    }

    @Test
    func readReturnsNilWhenNonNumericBootSegment() {
        let fake = FakeStore(seed: ["anchor": "1700000000000|123456|1700000000500|xx"])
        #expect(store(fake).read() == nil)
    }

    @Test
    func readReturnsNilWhenEmptyString() {
        let fake = FakeStore(seed: ["anchor": ""])
        #expect(store(fake).read() == nil)
    }
}
