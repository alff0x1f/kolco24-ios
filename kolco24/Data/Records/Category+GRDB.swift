//
//  Category+GRDB.swift
//  kolco24
//
//  GRDB-конформанс доменного типа `Category` — аналог Room-аннотаций
//  `CategoryEntity`. Extension в `Data/`, `Model/` без `import GRDB`.
//

import GRDB

extension Category: FetchableRecord, PersistableRecord {
    static let databaseTableName = "categories"

    init(row: Row) {
        self.init(
            id: row["id"],
            raceId: row["raceId"],
            code: row["code"],
            shortName: row["shortName"],
            name: row["name"],
            sortOrder: row["sortOrder"]
        )
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["raceId"] = raceId
        container["code"] = code
        container["shortName"] = shortName
        container["name"] = name
        container["sortOrder"] = sortOrder
    }
}
