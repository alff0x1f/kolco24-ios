//
//  MemberChipBinding+GRDB.swift
//  kolco24
//
//  GRDB-конформанс доменного типа `MemberChipBinding` (этап 1) — аналог
//  Room-аннотаций `MemberChipBindingEntity` (композитный PK `(teamId, numberInTeam)`,
//  индекс по `nfcUid`). Extension в `Data/`, `Model/` без `import GRDB`.
//

import GRDB

extension MemberChipBinding: FetchableRecord, PersistableRecord {
    static let databaseTableName = "member_chip_bindings"

    init(row: Row) {
        self.init(
            teamId: row["teamId"],
            numberInTeam: row["numberInTeam"],
            nfcUid: row["nfcUid"],
            participantNumber: row["participantNumber"]
        )
    }

    func encode(to container: inout PersistenceContainer) {
        container["teamId"] = teamId
        container["numberInTeam"] = numberInTeam
        container["nfcUid"] = nfcUid
        container["participantNumber"] = participantNumber
    }
}
