//
//  Race+GRDB.swift
//  kolco24
//
//  GRDB-конформанс доменного типа `Race` — аналог Room-аннотаций `RaceEntity`
//  (`@Entity(tableName = "races")`, `@PrimaryKey val id`). Держится extension'ом
//  в `Data/`, чтобы `Model/Race.swift` оставался без `import GRDB` (grep-инвариант
//  этапа 1/2). `init(row:)`/`encode(to:)` пишутся вручную — `Model/`-типы не Codable.
//

import GRDB

extension Race: FetchableRecord, PersistableRecord {
    static let databaseTableName = "races"

    init(row: Row) {
        self.init(
            id: row["id"],
            name: row["name"],
            slug: row["slug"],
            date: row["date"],
            dateEnd: row["dateEnd"],
            place: row["place"],
            regStatus: row["regStatus"]
        )
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["name"] = name
        container["slug"] = slug
        container["date"] = date
        container["dateEnd"] = dateEnd
        container["place"] = place
        container["regStatus"] = regStatus
    }
}
