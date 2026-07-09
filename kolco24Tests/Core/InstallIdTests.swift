//
//  InstallIdTests.swift
//  kolco24Tests
//
//  Зеркало `data/InstallIdTest.kt` 1:1: get-or-create UUID через in-memory seam.
//

import Testing
@testable import kolco24

struct InstallIdTests {

    /// Минимальный in-memory key-value store вместо UserDefaults.
    private final class FakeStore {
        var value: String?
        var saveCount = 0
        func load() -> String? { value }
        func save(_ v: String) {
            value = v
            saveCount += 1
        }
    }

    @Test
    func generatesAndPersistsOnFirstCall() {
        let store = FakeStore()

        let id = InstallId.getOrCreate(load: store.load, save: store.save)

        #expect(id == store.value)
        #expect(store.saveCount == 1)
    }

    @Test
    func returnsSameValueOnRepeatedCallsWithoutReSaving() {
        let store = FakeStore()

        let first = InstallId.getOrCreate(load: store.load, save: store.save)
        let second = InstallId.getOrCreate(load: store.load, save: store.save)

        #expect(first == second)
        #expect(store.saveCount == 1)
    }

    @Test
    func generatedIdIsAtMost64Chars() {
        let store = FakeStore()

        let id = InstallId.getOrCreate(load: store.load, save: store.save)

        #expect(id.count <= 64, "install id length \(id.count) exceeds 64")
    }
}
