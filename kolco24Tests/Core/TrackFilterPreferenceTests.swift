//
//  TrackFilterPreferenceTests.swift
//  kolco24Tests
//
//  Зеркало `data/TrackFilterPreferenceTest.kt`: начальное значение из `load`, сеттер обновляет
//  значение и персистит через `save`, reload новым инстансом.
//

import Testing
@testable import kolco24

struct TrackFilterPreferenceTests {

    private final class FakeStore {
        var value: Bool
        var saves: [Bool] = []

        init(value: Bool = false) {
            self.value = value
        }

        func load() -> Bool { value }
        func save(_ v: Bool) {
            value = v
            saves.append(v)
        }
    }

    @Test func initialValue_comesFromLoad() {
        #expect(TrackFilterPreference(load: FakeStore().load, save: { _ in }).showAllPoints == false)
        #expect(TrackFilterPreference(load: FakeStore(value: true).load, save: { _ in }).showAllPoints == true)
    }

    @Test func setter_updatesValueAndSaves() {
        let store = FakeStore()
        let pref = TrackFilterPreference(load: store.load, save: store.save)
        pref.setShowAllPoints(true)
        #expect(pref.showAllPoints)
        #expect(store.saves == [true])

        let reloaded = TrackFilterPreference(load: store.load, save: store.save)
        #expect(reloaded.showAllPoints)
    }
}
