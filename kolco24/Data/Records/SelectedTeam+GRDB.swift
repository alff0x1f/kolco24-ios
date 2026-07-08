//
//  SelectedTeam+GRDB.swift
//  kolco24
//
//  GRDB-конформанс доменного типа `SelectedTeam` — аналог Room-аннотаций
//  `SelectedTeamEntity`. Extension в `Data/`, `Model/` без `import GRDB`.
//

import GRDB

extension SelectedTeam: FetchableRecord, PersistableRecord {
    static let databaseTableName = "selected_team"

    init(row: Row) {
        self.init(
            id: row["id"],
            raceId: row["raceId"],
            teamId: row["teamId"]
        )
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["raceId"] = raceId
        container["teamId"] = teamId
    }
}
