//
//  ThemePreferenceTests.swift
//  kolco24Tests
//
//  Зеркало `data/ThemePreferenceTest.kt` 1:1: дефолт system, pre-seeded, unknown → system,
//  персист имени enum + reload новым инстансом.
//

import Testing
@testable import kolco24

struct ThemePreferenceTests {

    /// In-memory фейк инъецированного одноключевого store (зеркало Kotlin `FakeStore`).
    private final class FakeStore {
        var value: String?

        init(value: String? = nil) {
            self.value = value
        }

        func load() -> String? { value }
        func save(_ v: String) { value = v }
    }

    @Test
    func defaultsToSystem_whenStoreEmpty() {
        let store = FakeStore(value: nil)
        let pref = ThemePreference(load: store.load, save: store.save)
        #expect(pref.mode == .system)
    }

    @Test
    func parsesPreSeededValue_onInit() {
        let store = FakeStore(value: "DARK")
        let pref = ThemePreference(load: store.load, save: store.save)
        #expect(pref.mode == .dark)

        let store2 = FakeStore(value: "LIGHT")
        let pref2 = ThemePreference(load: store2.load, save: store2.save)
        #expect(pref2.mode == .light)
    }

    @Test
    func preSeededUnknownValue_fallsBackToSystem() {
        let store = FakeStore(value: "AUTO")
        let pref = ThemePreference(load: store.load, save: store.save)
        #expect(pref.mode == .system)
    }

    @Test
    func setMode_persistsEnumName_andEmitsNewValue() {
        let store = FakeStore(value: nil)
        let pref = ThemePreference(load: store.load, save: store.save)

        pref.setMode(.light)
        #expect(store.value == "LIGHT")
        #expect(pref.mode == .light)

        pref.setMode(.dark)
        #expect(store.value == "DARK")
        #expect(pref.mode == .dark)

        pref.setMode(.system)
        #expect(store.value == "SYSTEM")
        #expect(pref.mode == .system)
    }

    @Test
    func setMode_persistedValue_isReloadedByNewInstance() {
        let store = FakeStore(value: nil)
        ThemePreference(load: store.load, save: store.save).setMode(.dark)

        // Свежий инстанс (например, после гибели процесса) читает сохранённое значение синхронно.
        let reopened = ThemePreference(load: store.load, save: store.save)
        #expect(reopened.mode == .dark)
    }
}
