//
//  Mark+GRDB.swift
//  kolco24
//
//  GRDB-конформанс доменного типа `Mark` (этап 1) — аналог Room-аннотаций
//  `MarkEntity` (PK `id` (TEXT-UUID), индексы по `teamId`/`checkpointId`/`raceId`).
//  Две JSON-TEXT-колонки: `present` (`[Int]`, non-null, аналог `IntListConverter`)
//  и `presentDetails` (`[MarkMemberSnapshot]?`, nullable — NULL у легаси-строк,
//  аналог `MarkMemberSnapshotListConverter`). Кодеки живут здесь, `Model/` без
//  `import GRDB`.
//
//  `MarkMemberSnapshot` получает `Codable`-конформанс тоже здесь (в `Model/` тип не
//  Codable — конформансы живут в `Data/`). Опциональные поля читаются
//  `decodeIfPresent` (forward-compat + `code` с дефолтом nil в Kotlin).
//

import Foundation
import GRDB
import os

// MARK: - JSON-кодеки колонок `marks.present` / `marks.presentDetails`

/// Кодек JSON-колонки `marks.present` (`[Int]`, non-null; аналог `IntListConverter`).
/// `.sortedKeys` не влияет на массив, но держим общий стиль; битый JSON → `[]` + лог.
enum MarkPresentCodec {
    private static let logger = Logger(subsystem: "kolco24", category: "MarkPresentCodec")

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder = JSONDecoder()

    /// `[Int]` → JSON-строка; порядок и дубликаты сохраняются. Пустой список → `"[]"`.
    static func encode(_ values: [Int]) -> String {
        guard let data = try? encoder.encode(values),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// JSON-строка → `[Int]`; битый JSON → `[]` + лог (не краш).
    static func decode(_ value: String) -> [Int] {
        guard let data = value.data(using: .utf8) else { return [] }
        do {
            return try decoder.decode([Int].self, from: data)
        } catch {
            logger.error("Failed to decode Int list JSON: \(String(describing: error))")
            return []
        }
    }
}

/// Кодек JSON-колонки `marks.presentDetails` (`[MarkMemberSnapshot]?`, **nullable**;
/// аналог `MarkMemberSnapshotListConverter`). NULL ↔ nil (легаси-строки без снапшота
/// остаются nil); битый JSON → nil + лог, не краш.
enum MarkPresentDetailsCodec {
    private static let logger = Logger(subsystem: "kolco24", category: "MarkPresentDetailsCodec")

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder = JSONDecoder()

    /// `[MarkMemberSnapshot]?` → JSON-строка?; nil → nil, пустой список → `"[]"`.
    static func encode(_ values: [MarkMemberSnapshot]?) -> String? {
        guard let values else { return nil }
        guard let data = try? encoder.encode(values),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    /// JSON-строка? → `[MarkMemberSnapshot]?`; nil → nil, битый JSON → nil + лог.
    static func decode(_ value: String?) -> [MarkMemberSnapshot]? {
        guard let value else { return nil }
        guard let data = value.data(using: .utf8) else { return nil }
        do {
            return try decoder.decode([MarkMemberSnapshot].self, from: data)
        } catch {
            logger.error("Failed to decode snapshot list JSON: \(String(describing: error))")
            return nil
        }
    }
}

extension MarkMemberSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case numberInTeam, nfcUid, number, code
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            numberInTeam: try container.decode(Int.self, forKey: .numberInTeam),
            nfcUid: try container.decodeIfPresent(String.self, forKey: .nfcUid),
            number: try container.decode(Int.self, forKey: .number),
            code: try container.decodeIfPresent(String.self, forKey: .code)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(numberInTeam, forKey: .numberInTeam)
        try container.encode(nfcUid, forKey: .nfcUid)
        try container.encode(number, forKey: .number)
        try container.encode(code, forKey: .code)
    }
}

// MARK: - GRDB record

extension Mark: FetchableRecord, PersistableRecord {
    static let databaseTableName = "marks"

    init(row: Row) {
        self.init(
            id: row["id"],
            raceId: row["raceId"],
            teamId: row["teamId"],
            checkpointId: row["checkpointId"],
            checkpointNumber: row["checkpointNumber"],
            cost: row["cost"],
            method: row["method"],
            cpUid: row["cpUid"],
            cpCode: row["cpCode"],
            present: MarkPresentCodec.decode(row["present"]),
            presentDetails: MarkPresentDetailsCodec.decode(row["presentDetails"]),
            expectedCount: row["expectedCount"],
            complete: row["complete"],
            photoPath: row["photoPath"],
            takenAt: row["takenAt"],
            updatedAt: row["updatedAt"],
            uploadedLocal: row["uploadedLocal"],
            uploadedCloud: row["uploadedCloud"],
            photosUploadedLocal: row["photosUploadedLocal"],
            photosUploadedCloud: row["photosUploadedCloud"],
            trustedTakenAt: row["trustedTakenAt"],
            elapsedRealtimeAt: row["elapsedRealtimeAt"],
            bootCount: row["bootCount"],
            locLat: row["locLat"],
            locLon: row["locLon"],
            locAccuracy: row["locAccuracy"],
            locAltitude: row["locAltitude"],
            locVerticalAccuracy: row["locVerticalAccuracy"],
            locGpsTimeMs: row["locGpsTimeMs"],
            locElapsedRealtimeAt: row["locElapsedRealtimeAt"]
        )
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["raceId"] = raceId
        container["teamId"] = teamId
        container["checkpointId"] = checkpointId
        container["checkpointNumber"] = checkpointNumber
        container["cost"] = cost
        container["method"] = method
        container["cpUid"] = cpUid
        container["cpCode"] = cpCode
        container["present"] = MarkPresentCodec.encode(present)
        container["presentDetails"] = MarkPresentDetailsCodec.encode(presentDetails)
        container["expectedCount"] = expectedCount
        container["complete"] = complete
        container["photoPath"] = photoPath
        container["takenAt"] = takenAt
        container["updatedAt"] = updatedAt
        container["uploadedLocal"] = uploadedLocal
        container["uploadedCloud"] = uploadedCloud
        container["photosUploadedLocal"] = photosUploadedLocal
        container["photosUploadedCloud"] = photosUploadedCloud
        container["trustedTakenAt"] = trustedTakenAt
        container["elapsedRealtimeAt"] = elapsedRealtimeAt
        container["bootCount"] = bootCount
        container["locLat"] = locLat
        container["locLon"] = locLon
        container["locAccuracy"] = locAccuracy
        container["locAltitude"] = locAltitude
        container["locVerticalAccuracy"] = locVerticalAccuracy
        container["locGpsTimeMs"] = locGpsTimeMs
        container["locElapsedRealtimeAt"] = locElapsedRealtimeAt
    }
}
