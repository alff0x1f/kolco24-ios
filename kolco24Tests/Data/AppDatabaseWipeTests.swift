//
//  AppDatabaseWipeTests.swift
//  kolco24Tests
//
//  Тест `AppDatabase.wipeAllTables()` — «Очистить базу данных» из скрытой
//  отладки этапа 9. Без Kotlin-зеркала (на Android чистка через
//  `clearAllTables()` Room). Проверяем: посеянные строки в нескольких таблицах
//  (вкл. `selected_team` и `sync_meta`) исчезают, а схема остаётся жива —
//  повторный insert после wipe работает.
//

import GRDB
import Testing
@testable import kolco24

struct AppDatabaseWipeTests {

    /// Кол-во строк в таблице.
    private func count(_ db: any DatabaseWriter, _ table: String) throws -> Int {
        try db.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    @Test func wipeClearsSeededRowsAndKeepsSchemaAlive() async throws {
        let appDb = try AppDatabase.makeInMemory()
        let db = appDb.writer

        // Посеять по строке в несколько таблиц (вкл. selected_team и sync_meta).
        try await db.write { database in
            try database.execute(sql: """
                INSERT INTO races (id, name, slug, date, place, regStatus)
                VALUES (1, 'Race', 'race', '2026-07-11', 'Place', 'open')
                """)
            try database.execute(sql: """
                INSERT INTO selected_team (id, raceId, teamId) VALUES (1, 1, 42)
                """)
            try database.execute(sql: """
                INSERT INTO sync_meta (origin, resource, etag)
                VALUES ('https://api', 'races', 'W/"abc"')
                """)
            try database.execute(sql: """
                INSERT INTO teams (id, raceId, teamname, ucount, paidPeople,
                    startTime, finishTime, members)
                VALUES (42, 1, 'Team', 2, 0.0, 0, 0, '[]')
                """)
            try database.execute(sql: """
                INSERT INTO marks (id, raceId, teamId, checkpointId, checkpointNumber,
                    cost, method, cpUid, cpCode, present, expectedCount, complete,
                    takenAt, updatedAt, uploadedLocal, uploadedCloud,
                    photosUploadedLocal, photosUploadedCloud)
                VALUES ('m1', 1, 42, 7, 7, 4, 'nfc', 'uid', 'code', '[]', 2, 1,
                    100, 100, 0, 0, 0, 0)
                """)
        }

        // Sanity: строки на месте.
        #expect(try count(db, "races") == 1)
        #expect(try count(db, "selected_team") == 1)
        #expect(try count(db, "sync_meta") == 1)
        #expect(try count(db, "teams") == 1)
        #expect(try count(db, "marks") == 1)

        // Очистка.
        try await appDb.wipeAllTables()

        // Все 13 таблиц пусты.
        for table in AppDatabase.allTableNames {
            #expect(try count(db, table) == 0, "table \(table) not empty after wipe")
        }

        // Схема жива: повторный insert работает.
        try await db.write { database in
            try database.execute(sql: """
                INSERT INTO races (id, name, slug, date, place, regStatus)
                VALUES (2, 'Race 2', 'race2', '2026-07-12', 'Place', 'open')
                """)
        }
        #expect(try count(db, "races") == 1)
    }

    /// Анти-регресс: `allTableNames` обязан покрывать РОВНО реальный набор таблиц (тот же запрос к
    /// `sqlite_master`, что в `AppDatabaseSchemaTests`). Без этого забытая в списке таблица
    /// (добавленная в схему позже) осталась бы с непочищенными строками, а wipe-тест выше — зелёным
    /// (он итерирует сам `allTableNames`, а не независимый источник истины).
    @Test func allTableNamesCoversEveryRealTable() throws {
        let appDb = try AppDatabase.makeInMemory()
        let actualTables = try appDb.writer.read { database -> Set<String> in
            let names = try String.fetchAll(database, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                  AND name != 'grdb_migrations'
                """)
            return Set(names)
        }
        #expect(Set(AppDatabase.allTableNames) == actualTables)
    }
}
