//
//  TrackColorPreferenceTests.swift
//  kolco24Tests
//
//  Тумблер «Цвет трека по скорости»: начальное значение из `load`, сеттер персистит через `save`,
//  продовый адаптер по умолчанию включён.
//

import Foundation
import Testing
@testable import kolco24

struct TrackColorPreferenceTests {

    private final class FakeStore {
        var value: Bool
        var saves: [Bool] = []

        init(value: Bool) {
            self.value = value
        }

        func load() -> Bool { value }
        func save(_ v: Bool) {
            value = v
            saves.append(v)
        }
    }

    @Test func initialValue_comesFromLoad() {
        #expect(TrackColorPreference(load: FakeStore(value: false).load, save: { _ in }).colorBySpeed == false)
        #expect(TrackColorPreference(load: FakeStore(value: true).load, save: { _ in }).colorBySpeed == true)
    }

    @Test func setter_updatesValueAndSaves() {
        let store = FakeStore(value: true)
        let pref = TrackColorPreference(load: store.load, save: store.save)
        pref.setColorBySpeed(false)
        #expect(pref.colorBySpeed == false)
        #expect(store.saves == [false])

        let reloaded = TrackColorPreference(load: store.load, save: store.save)
        #expect(reloaded.colorBySpeed == false)
    }

    @Test func fromUserDefaults_defaultsToOnAndPersists() throws {
        let suite = "TrackColorPreferenceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(TrackColorPreference.fromUserDefaults(defaults).colorBySpeed == true)
        TrackColorPreference.fromUserDefaults(defaults).setColorBySpeed(false)
        #expect(TrackColorPreference.fromUserDefaults(defaults).colorBySpeed == false)
    }
}
