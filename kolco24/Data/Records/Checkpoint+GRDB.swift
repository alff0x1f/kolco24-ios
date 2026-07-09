//
//  Checkpoint+GRDB.swift
//  kolco24
//
//  GRDB-конформанс доменного типа `Checkpoint` (этап 1) — аналог Room-аннотаций
//  `CheckpointEntity` (PK `id`, индекс по `raceId`). `locked` — Bool ↔ INTEGER 0/1
//  (GRDB конвертирует нативно). Extension в `Data/`, `Model/` без `import GRDB`.
//

import GRDB

extension Checkpoint: FetchableRecord, PersistableRecord {
    static let databaseTableName = "checkpoints"

    init(row: Row) {
        self.init(
            id: row["id"],
            raceId: row["raceId"],
            number: row["number"],
            cost: row["cost"],
            type: row["type"],
            description: row["description"],
            locked: row["locked"],
            encIv: row["encIv"],
            encCt: row["encCt"],
            color: row["color"]
        )
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["raceId"] = raceId
        container["number"] = number
        container["cost"] = cost
        container["type"] = type
        container["description"] = description
        container["locked"] = locked
        container["encIv"] = encIv
        container["encCt"] = encCt
        container["color"] = color
    }
}
