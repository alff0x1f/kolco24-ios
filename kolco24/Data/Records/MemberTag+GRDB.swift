//
//  MemberTag+GRDB.swift
//  kolco24
//
//  GRDB-конформанс доменного типа `MemberTag` — аналог Room-аннотаций
//  `MemberTagEntity` (композитный PK `(raceId, nfcUid)`). Extension в `Data/`,
//  `Model/` без `import GRDB`.
//

import GRDB

extension MemberTag: FetchableRecord, PersistableRecord {
    static let databaseTableName = "member_tags"

    init(row: Row) {
        self.init(
            raceId: row["raceId"],
            nfcUid: row["nfcUid"],
            number: row["number"]
        )
    }

    func encode(to container: inout PersistenceContainer) {
        container["raceId"] = raceId
        container["nfcUid"] = nfcUid
        container["number"] = number
    }
}
