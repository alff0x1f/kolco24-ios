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
        let pattern = /^[a-z][a-zA-Z0-9]*(\.[a-zA-Z0-9]+)+$/
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
}
