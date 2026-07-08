//
//  Secrets.swift
//  kolco24
//
//  Секреты API, прокинутые по цепочке Config/Secrets.xcconfig → Info.plist → Bundle.main.
//  Отсутствие или пустота значения — громкий отказ (fatalError): значит,
//  `Config/Secrets.xcconfig` не заполнен (скопируй `Config/Secrets.example.xcconfig`).
//

import Foundation

enum Secrets {
    static var apiBaseURL: String { require("Kolco24APIBaseURL") }
    static var appKeyId: String { require("Kolco24AppKeyId") }
    static var appSecret: String { require("Kolco24AppSecret") }
    static var localAPIBaseURL: String { require("Kolco24LocalAPIBaseURL") }

    /// Внутренний шов для тестов: `nil` при отсутствующем, пустом, нестроковом
    /// или неподставленном (`$(VAR)`) значении. Xcode разворачивает
    /// неопределённую переменную в пустую строку (проверено эмпирически),
    /// так что проверка на `$(` — защита в глубину на случай plist,
    /// собранного в обход подстановки Xcode.
    static func value(forInfoPlistKey key: String, in info: [String: Any]) -> String? {
        guard let value = info[key] as? String, !value.isEmpty, !value.contains("$(") else {
            return nil
        }
        return value
    }

    private static func require(_ key: String) -> String {
        guard let value = value(forInfoPlistKey: key, in: Bundle.main.infoDictionary ?? [:]) else {
            fatalError(
                "Missing or empty Info.plist value for key '\(key)'. "
                    + "Fill in Config/Secrets.xcconfig (copy Config/Secrets.example.xcconfig) and rebuild."
            )
        }
        return value
    }
}
