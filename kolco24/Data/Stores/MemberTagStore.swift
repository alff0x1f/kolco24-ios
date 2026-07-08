//
//  MemberTagStore.swift
//  kolco24
//
//  Store-структура над таблицей `member_tags` (композитный PK `(raceId, nfcUid)`) —
//  порт `data/db/MemberTagDao.kt` (этап 2). `@Insert(REPLACE)` → `.replace`.
//

import GRDB

struct MemberTagStore {
    let dbWriter: any DatabaseWriter

    init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    /// `SELECT * FROM member_tags WHERE raceId = :raceId ORDER BY number, nfcUid`.
    func observeForRace(_ raceId: Int) -> AsyncValueObservation<[MemberTag]> {
        ValueObservation
            .tracking { db in
                try MemberTag.fetchAll(
                    db,
                    sql: "SELECT * FROM member_tags WHERE raceId = ? ORDER BY number, nfcUid",
                    arguments: [raceId]
                )
            }
            .values(in: dbWriter)
    }

    func findByUid(raceId: Int, nfcUid: String) async throws -> MemberTag? {
        try await dbWriter.read { db in
            try MemberTag.fetchOne(
                db,
                sql: "SELECT * FROM member_tags WHERE raceId = ? AND nfcUid = ?",
                arguments: [raceId, nfcUid]
            )
        }
    }

    func insertAll(_ tags: [MemberTag]) async throws {
        try await dbWriter.write { db in
            for tag in tags {
                try tag.insert(db, onConflict: .replace)
            }
        }
    }

    func deleteForRace(_ raceId: Int) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM member_tags WHERE raceId = ?", arguments: [raceId])
        }
    }

    /// Полная замена пула member-тегов одной гонки на `200`: wipe → re-insert, атомарно.
    func replaceAllForRace(raceId: Int, tags: [MemberTag]) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM member_tags WHERE raceId = ?", arguments: [raceId])
            for tag in tags {
                try tag.insert(db, onConflict: .replace)
            }
        }
    }
}
