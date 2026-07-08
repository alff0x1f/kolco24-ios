//
//  Team+GRDB.swift
//  kolco24
//
//  GRDB-конформанс доменного типа `Team` — аналог Room-аннотаций `TeamEntity`
//  (PK `id`, индекс по `raceId`). Колонка `members` — JSON-TEXT (аналог Room
//  `TeamMembersConverter`): кодируется здесь же, `Model/` без `import GRDB`.
//
//  `TeamMemberItem` получает `Codable`-конформанс тоже здесь (в `Model/` тип не
//  Codable — зеркало правила «конформансы живут в `Data/`»), с CodingKey
//  `number_in_team` (аналог Kotlin `@SerialName("number_in_team")`).
//

import Foundation
import GRDB
import os

// MARK: - JSON-кодек колонки `teams.members` (аналог `TeamMembersConverter`)

/// Кодек JSON-колонки `teams.members`. Порт `TeamMembersConverter`:
/// `.sortedKeys` для стабильного вывода в тестах; незнакомые ключи игнорируются
/// (Swift `Decodable` по умолчанию, аналог kotlinx `ignoreUnknownKeys = true`);
/// битый JSON → пустой список + лог, не краш.
enum TeamMembersCodec {
    private static let logger = Logger(subsystem: "kolco24", category: "TeamMembersCodec")

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    private static let decoder = JSONDecoder()

    /// `[TeamMemberItem]` → JSON-строка. Пустой список → `"[]"`.
    static func encode(_ members: [TeamMemberItem]) -> String {
        guard let data = try? encoder.encode(members),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// JSON-строка → `[TeamMemberItem]`; битый JSON → `[]` + лог (не краш).
    static func decode(_ value: String) -> [TeamMemberItem] {
        guard let data = value.data(using: .utf8) else { return [] }
        do {
            return try decoder.decode([TeamMemberItem].self, from: data)
        } catch {
            logger.error("Failed to decode members JSON: \(String(describing: error))")
            return []
        }
    }
}

extension TeamMemberItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case name
        case numberInTeam = "number_in_team"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            numberInTeam: try container.decode(Int.self, forKey: .numberInTeam)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(numberInTeam, forKey: .numberInTeam)
    }
}

// MARK: - GRDB record

extension Team: FetchableRecord, PersistableRecord {
    static let databaseTableName = "teams"

    init(row: Row) {
        self.init(
            id: row["id"],
            raceId: row["raceId"],
            teamname: row["teamname"],
            startNumber: row["startNumber"],
            categoryId: row["categoryId"],
            ucount: row["ucount"],
            paidPeople: row["paidPeople"],
            startTime: row["startTime"],
            finishTime: row["finishTime"],
            members: TeamMembersCodec.decode(row["members"])
        )
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["raceId"] = raceId
        container["teamname"] = teamname
        container["startNumber"] = startNumber
        container["categoryId"] = categoryId
        container["ucount"] = ucount
        container["paidPeople"] = paidPeople
        container["startTime"] = startTime
        container["finishTime"] = finishTime
        container["members"] = TeamMembersCodec.encode(members)
    }
}
