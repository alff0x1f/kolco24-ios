//
//  GRDBSmokeTests.swift
//  kolco24Tests
//
//  Смоук-тест SPM-зависимости GRDB: модуль импортируется (видимость через
//  host application), in-memory база открывается, тривиальный SQL выполняется.
//

import GRDB
import Testing

struct GRDBSmokeTests {

    @Test func inMemoryDatabaseQueueExecutesTrivialQuery() throws {
        let dbQueue = try DatabaseQueue()
        let value = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT 1 + 1")
        }
        #expect(value == 2)
    }

    @Test func createTableInsertAndFetch() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: "CREATE TABLE checkpoint (number TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO checkpoint (number) VALUES (?)", arguments: ["4-07"])
        }
        let count = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM checkpoint")
        }
        #expect(count == 1)
    }
}
