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
    static var apiBaseURL: String { value(forInfoPlistKey: "Kolco24APIBaseURL") }
    static var appKeyId: String { value(forInfoPlistKey: "Kolco24AppKeyId") }
    static var appSecret: String { value(forInfoPlistKey: "Kolco24AppSecret") }
    static var localAPIBaseURL: String { value(forInfoPlistKey: "Kolco24LocalAPIBaseURL") }

    private static func value(forInfoPlistKey key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty
        else {
            fatalError(
                "Missing or empty Info.plist value for key '\(key)'. "
                    + "Fill in Config/Secrets.xcconfig (copy Config/Secrets.example.xcconfig) and rebuild."
            )
        }
        return value
    }
}
