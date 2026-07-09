//
//  JSONColumnCodec.swift
//  kolco24
//
//  Общий движок JSON-кодеков TEXT-колонок GRDB (этап 2). Держит единый
//  `JSONEncoder(.sortedKeys)` + `JSONDecoder`; именованные кодеки
//  (`MarkPresentCodec`, `MarkPresentDetailsCodec`, `TeamMembersCodec`,
//  `MarkPhotoPaths`) делегируют сюда, сохраняя 1:1-соответствие Kotlin-
//  `TypeConverter`'ам и свою fallback-семантику (`[]` / `nil`). Битый JSON →
//  fallback + лог, никогда не краш.
//

import Foundation
import os

enum JSONColumnCodec {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder = JSONDecoder()

    /// `T` → JSON-строка; при сбое кодирования → `fallback` (напр. `"[]"`).
    static func encode<T: Encodable>(_ value: T, fallback: String) -> String {
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return fallback
        }
        return json
    }

    /// `T` → JSON-строка?; при сбое кодирования → `nil` (nullable-колонки).
    static func encodeOptional<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    /// JSON-строка → `T`; nil/битый JSON → `fallback` + лог (не краш).
    static func decode<T: Decodable>(_ value: String?, as type: T.Type, category: String, fallback: T) -> T {
        guard let value, let data = value.data(using: .utf8) else { return fallback }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Logger(subsystem: "kolco24", category: category)
                .error("Failed to decode \(category) JSON: \(String(describing: error))")
            return fallback
        }
    }

    /// JSON-строка? → `T?`; nil/битый JSON → `nil` + лог (nullable-колонки).
    static func decodeOptional<T: Decodable>(_ value: String?, as type: T.Type, category: String) -> T? {
        guard let value, let data = value.data(using: .utf8) else { return nil }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Logger(subsystem: "kolco24", category: category)
                .error("Failed to decode \(category) JSON: \(String(describing: error))")
            return nil
        }
    }
}
