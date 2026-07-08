//
//  SyncMeta+GRDB.swift
//  kolco24
//
//  GRDB-конформанс доменного типа `SyncMeta` — аналог Room-аннотаций
//  `SyncMetaEntity` (композитный PK `(origin, resource)`). Extension в `Data/`,
//  `Model/` без `import GRDB`.
//

import GRDB

extension SyncMeta: FetchableRecord, PersistableRecord {
    static let databaseTableName = "sync_meta"

    init(row: Row) {
        self.init(
            origin: row["origin"],
            resource: row["resource"],
            etag: row["etag"]
        )
    }

    func encode(to container: inout PersistenceContainer) {
        container["origin"] = origin
        container["resource"] = resource
        container["etag"] = etag
    }
}
