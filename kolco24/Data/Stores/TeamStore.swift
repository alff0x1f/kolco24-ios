//
//  TeamStore.swift
//  kolco24
//
//  Store-структура над таблицами `teams` + `categories` — порт `data/db/TeamDao.kt`
//  (этап 2). Сложная сортировка `startNumber` (NULL/''/числа) перенесена дословной
//  строкой SQL — цель сверяемость с Android, не красота DSL. `replaceAllForRace` —
//  одна транзакция над **двумя** таблицами. `@Insert(REPLACE)` → `.replace`.
//

import GRDB

struct TeamStore {
    let dbWriter: any DatabaseWriter

    init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    /// Дословный SQL из `TeamDao.observeTeamsForRace` — сортировка `startNumber`:
    /// сперва не-пустые (NULL/'' в конце), затем числовой каст, затем строкой, затем id.
    func observeTeamsForRace(_ raceId: Int) -> AsyncValueObservation<[Team]> {
        ValueObservation
            .tracking { db in
                try Team.fetchAll(
                    db,
                    sql: "SELECT * FROM teams WHERE raceId = ? ORDER BY (startNumber IS NULL OR startNumber = ''), CAST(NULLIF(startNumber, '') AS INTEGER), startNumber, id",
                    arguments: [raceId]
                )
            }
            .values(in: dbWriter)
    }

    /// `SELECT * FROM categories WHERE raceId = :raceId ORDER BY sortOrder, id`.
    func observeCategoriesForRace(_ raceId: Int) -> AsyncValueObservation<[Category]> {
        ValueObservation
            .tracking { db in
                try Category.fetchAll(
                    db,
                    sql: "SELECT * FROM categories WHERE raceId = ? ORDER BY sortOrder, id",
                    arguments: [raceId]
                )
            }
            .values(in: dbWriter)
    }

    /// `SELECT * FROM teams WHERE id = :teamId`.
    func observeTeamById(_ teamId: Int) -> AsyncValueObservation<Team?> {
        ValueObservation
            .tracking { db in
                try Team.fetchOne(db, sql: "SELECT * FROM teams WHERE id = ?", arguments: [teamId])
            }
            .values(in: dbWriter)
    }

    func insertTeams(_ teams: [Team]) async throws {
        try await dbWriter.write { db in
            for team in teams {
                try team.insert(db, onConflict: .replace)
            }
        }
    }

    func insertCategories(_ categories: [Category]) async throws {
        try await dbWriter.write { db in
            for category in categories {
                try category.insert(db, onConflict: .replace)
            }
        }
    }

    func deleteTeamsForRace(_ raceId: Int) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM teams WHERE raceId = ?", arguments: [raceId])
        }
    }

    func deleteCategoriesForRace(_ raceId: Int) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM categories WHERE raceId = ?", arguments: [raceId])
        }
    }

    /// Полная замена команд + категорий одной гонки на `200`: wipe → re-insert,
    /// атомарно над **двумя** таблицами (порядок как в Kotlin `replaceAllForRace`).
    func replaceAllForRace(
        raceId: Int,
        categories: [Category],
        teams: [Team]
    ) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM teams WHERE raceId = ?", arguments: [raceId])
            try db.execute(sql: "DELETE FROM categories WHERE raceId = ?", arguments: [raceId])
            for category in categories {
                try category.insert(db, onConflict: .replace)
            }
            for team in teams {
                try team.insert(db, onConflict: .replace)
            }
        }
    }
}
