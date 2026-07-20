//
//  RaceStore.swift
//  kolco24
//
//  Store-структура над таблицей `races` — порт `data/db/RaceDao.kt` (этап 2).
//  Kotlin `suspend` → `async throws` через `write`; Kotlin `Flow` →
//  `ValueObservation.tracking{…}.values(in:)`. SQL из DAO переносится дословно
//  (порт-инвариант). `@Insert(REPLACE)` → `insert(db, onConflict: .replace)`.
//

import GRDB

/// Offline source of truth для списка гонок в UI.
struct RaceStore {
    let dbWriter: any DatabaseWriter

    init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    /// `SELECT * FROM races ORDER BY date DESC, id DESC`.
    func observeRaces() -> AsyncValueObservation<[Race]> {
        ValueObservation
            .tracking { db in
                try Race.fetchAll(db, sql: "SELECT * FROM races ORDER BY date DESC, id DESC")
            }
            .values(in: dbWriter)
    }

    /// Разовый снимок одной гонки по id (или `nil`, если строки нет) — источник `mapUrl` для машины
    /// состояний `MapModel` (доступность оффлайн-подложки; `nil` гонка → `noMapForRace`).
    func getById(_ id: Int) async throws -> Race? {
        try await dbWriter.read { db in
            try Race.fetchOne(db, sql: "SELECT * FROM races WHERE id = ?", arguments: [id])
        }
    }

    func insertAll(_ races: [Race]) async throws {
        try await dbWriter.write { db in
            for race in races {
                try race.insert(db, onConflict: .replace)
            }
        }
    }

    func deleteAll() async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM races")
        }
    }

    /// Полная замена на `200`: wipe → re-insert, атомарно (одна транзакция).
    func replaceAll(_ races: [Race]) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM races")
            for race in races {
                try race.insert(db, onConflict: .replace)
            }
        }
    }
}
