//
//  LegendMeta+GRDB.swift
//  kolco24
//
//  GRDB-конформанс доменного типа `LegendMeta` — аналог Room-аннотаций
//  `LegendMetaEntity` (PK `raceId`). Extension в `Data/`, `Model/` без `import GRDB`.
//

import GRDB

extension LegendMeta: FetchableRecord, PersistableRecord {
    static let databaseTableName = "legend_meta"

    init(row: Row) {
        self.init(
            raceId: row["raceId"],
            totalCost: row["totalCost"],
            scoringCount: row["scoringCount"]
        )
    }

    func encode(to container: inout PersistenceContainer) {
        container["raceId"] = raceId
        container["totalCost"] = totalCost
        container["scoringCount"] = scoringCount
    }
}
