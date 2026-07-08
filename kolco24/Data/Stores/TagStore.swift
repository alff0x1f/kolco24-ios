//
//  TagStore.swift
//  kolco24
//
//  Store-структура над таблицей `tags` (композитный PK `(raceId, bid)`) —
//  порт `data/db/TagDao.kt` (этап 2). `@Insert(REPLACE)` → `.replace`.
//

import GRDB

struct TagStore {
    let dbWriter: any DatabaseWriter

    init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    /// `SELECT * FROM tags WHERE raceId = :raceId ORDER BY checkpointId, bid`.
    func observeTagsForRace(_ raceId: Int) -> AsyncValueObservation<[Tag]> {
        ValueObservation
            .tracking { db in
                try Tag.fetchAll(
                    db,
                    sql: "SELECT * FROM tags WHERE raceId = ? ORDER BY checkpointId, bid",
                    arguments: [raceId]
                )
            }
            .values(in: dbWriter)
    }

    /// Ищет отсканированный тег по производному [bid] внутри [raceId]; `nil` — тег неизвестен.
    func getByBid(bid: String, raceId: Int) async throws -> Tag? {
        try await dbWriter.read { db in
            try Tag.fetchOne(
                db,
                sql: "SELECT * FROM tags WHERE bid = ? AND raceId = ?",
                arguments: [bid, raceId]
            )
        }
    }

    func insertTags(_ tags: [Tag]) async throws {
        try await dbWriter.write { db in
            for tag in tags {
                try tag.insert(db, onConflict: .replace)
            }
        }
    }

    func deleteTagsForRace(_ raceId: Int) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM tags WHERE raceId = ?", arguments: [raceId])
        }
    }

    /// Полная замена тегов одной гонки на `200`: wipe → re-insert, атомарно.
    func replaceAllForRace(raceId: Int, tags: [Tag]) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM tags WHERE raceId = ?", arguments: [raceId])
            for tag in tags {
                try tag.insert(db, onConflict: .replace)
            }
        }
    }
}
