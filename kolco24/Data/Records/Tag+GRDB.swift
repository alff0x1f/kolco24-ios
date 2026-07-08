//
//  Tag+GRDB.swift
//  kolco24
//
//  GRDB-конформанс доменного типа `Tag` — аналог Room-аннотаций `TagEntity`
//  (композитный PK `(raceId, bid)`). Extension в `Data/`, `Model/` без `import GRDB`.
//

import GRDB

extension Tag: FetchableRecord, PersistableRecord {
    static let databaseTableName = "tags"

    init(row: Row) {
        self.init(
            raceId: row["raceId"],
            bid: row["bid"],
            checkpointId: row["checkpointId"],
            checkMethod: row["checkMethod"],
            iv: row["iv"],
            ct: row["ct"]
        )
    }

    func encode(to container: inout PersistenceContainer) {
        container["raceId"] = raceId
        container["bid"] = bid
        container["checkpointId"] = checkpointId
        container["checkMethod"] = checkMethod
        container["iv"] = iv
        container["ct"] = ct
    }
}
