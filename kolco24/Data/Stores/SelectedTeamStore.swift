//
//  SelectedTeamStore.swift
//  kolco24
//
//  Store-структура над одно-строчной таблицей `selected_team` (фикс. PK id=1) —
//  порт `data/db/SelectedTeamDao.kt` (этап 2). `@Upsert` → `upsert(db)`.
//

import GRDB

struct SelectedTeamStore {
    let dbWriter: any DatabaseWriter

    init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    /// `SELECT * FROM selected_team WHERE id = 1`.
    func observe() -> AsyncValueObservation<SelectedTeam?> {
        ValueObservation
            .tracking { db in
                try SelectedTeam.fetchOne(db, sql: "SELECT * FROM selected_team WHERE id = 1")
            }
            .values(in: dbWriter)
    }

    func upsert(_ selected: SelectedTeam) async throws {
        try await dbWriter.write { db in
            try selected.upsert(db)
        }
    }

    func clear() async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM selected_team")
        }
    }
}
