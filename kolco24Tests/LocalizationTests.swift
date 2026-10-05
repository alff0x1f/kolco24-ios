//
//  LocalizationTests.swift
//  kolco24Tests
//
//  Каталог `Localizable.xcstrings` компилируется в `ru.lproj`/`en.lproj`
//  (`Localizable.strings` + `.stringsdict` для плюралов). Ключ без en-значения
//  в `en.lproj` не попадает — поэтому полнота проверяется сравнением множеств
//  ключей. Исходный `.xcstrings` в бандл не входит.
//

import Foundation
import Testing
@testable import kolco24

struct LocalizationTests {

    @Test func testsRunInRussian() {
        // Русские ассерты всего набора держатся на этом: язык задаёт Test action
        // shared-схемы kolco24 (или `-testLanguage ru -testRegion RU`).
        #expect(
            Bundle.main.preferredLocalizations.first == "ru",
            "Тесты должны идти в ru: запускайте через shared-схему kolco24 (TestAction language = ru)"
        )
    }

    @Test func everyKeyHasRussianAndEnglish() throws {
        let ru = try Self.catalog("ru")
        let en = try Self.catalog("en")
        #expect(!ru.isEmpty)
        #expect(Set(ru.keys) == Set(en.keys), "без пары: \(Set(ru.keys).symmetricDifference(en.keys).sorted())")
        for (key, value) in ru { #expect(!value.isEmpty && value != key, "нет ru: \(key)") }
        for (key, value) in en { #expect(!value.isEmpty && value != key, "нет en: \(key)") }
    }

    @Test func keysAreSemantic() throws {
        // Без цифр: генератор символов пишет букву после цифры заглавной (`a11y` → `A11Y`).
        let pattern = /^[a-z][a-zA-Z]*(\.[a-zA-Z]+)+$/
        for key in try Self.catalog("ru").keys {
            #expect(key.wholeMatch(of: pattern) != nil, "не семантический ключ: \(key)")
        }
    }

    @Test func resolvesBothLanguages() {
        #expect(ru(.commonCancel) == "Отмена")
        #expect(en(.commonCancel) == "Cancel")
        #expect(String(localized: .commonCancel) == "Отмена")
    }

    /// Ключ → значение (для плюрала — непустой маркер) из скомпилированного каталога.
    private static func catalog(_ language: String) throws -> [String: String] {
        let dir = try #require(Bundle.main.path(forResource: language, ofType: "lproj"), "нет \(language).lproj")
        var result: [String: String] = [:]
        if let strings = NSDictionary(contentsOfFile: dir + "/Localizable.strings") as? [String: String] {
            result.merge(strings) { a, _ in a }
        }
        if let plurals = NSDictionary(contentsOfFile: dir + "/Localizable.stringsdict") as? [String: Any] {
            for key in plurals.keys { result[key] = "plural" }
        }
        return result
    }

    @Test func appModelEnglishTexts() {
        #expect(en(.uploadPendingCount(3)) == "3 not sent")
        #expect(en(.scanStatusProgress("7", 2, 4)) == "CP 7 · chips 2/4")
        #expect(en(.localModeUntil("14:30")) == "Local mode until 14:30")
        #expect(en(.commonBytesMb) == "MB")
    }

    @Test func russianPluralForms() {
        // Правила CLDR ru: 1, 21 → one; 2–4, 22 → few; 0, 5–20, 11–14, 25 → many.
        #expect(ru(.commonPointsCount(1)) == "1 балл")
        #expect(ru(.commonPointsCount(21)) == "21 балл")
        #expect(ru(.commonPointsCount(2)) == "2 балла")
        #expect(ru(.commonPointsCount(22)) == "22 балла")
        #expect(ru(.commonPointsCount(0)) == "0 баллов")
        #expect(ru(.commonPointsCount(5)) == "5 баллов")
        #expect(ru(.commonPointsCount(11)) == "11 баллов")
        #expect(ru(.commonPointsCount(14)) == "14 баллов")
        #expect(ru(.scanTimerRemainingChips(1)) == "Остался 1 чип")
        #expect(ru(.scanTimerRemainingChips(3)) == "Осталось 3 чипа")
        #expect(ru(.teamChipsUnbound(5)) == "5 чипов не привязаны")
        #expect(ru(.trackPointsCount(2)) == "2 точки")
    }

    @Test func englishPluralForms() {
        #expect(en(.commonPointsCount(1)) == "1 point")
        #expect(en(.commonPointsCount(2)) == "2 points")
        #expect(en(.scanTimerRemainingChips(1)) == "1 chip left")
        #expect(en(.checkChipOthersOnCp(2)) == "2 more chips on this CP")
    }

    @Test func languageRowNamesActiveLanguage() {
        // Значение берётся из каталога, поэтому само называет язык, на котором показано приложение.
        #expect(ru(.settingsLanguageCurrent) == "Русский")
        #expect(en(.settingsLanguageCurrent) == "English")
        #expect(String(localized: .settingsLanguageCurrent) == "Русский")
    }
}
