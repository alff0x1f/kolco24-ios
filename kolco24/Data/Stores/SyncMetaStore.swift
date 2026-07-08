//
//  SyncMetaStore.swift
//  kolco24
//
//  Store-структура над таблицей `sync_meta` (композитный PK `(origin, resource)`) —
//  порт `data/db/SyncMetaDao.kt` (этап 2). `@Upsert` → `upsert(db)`.
//  `observeEtagsExist` — реактивный близнец presence-проверки `getEtag` сразу для
//  двух ключей ресурса (SQL `SELECT EXISTS(… resource IN (…))` дословно).
//

import GRDB

struct SyncMetaStore {
    let dbWriter: any DatabaseWriter

    init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    func getEtag(origin: String, resource: String) async throws -> String? {
        try await dbWriter.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT etag FROM sync_meta WHERE origin = ? AND resource = ?",
                arguments: [origin, resource]
            )
        }
    }

    /// `SELECT EXISTS(SELECT 1 FROM sync_meta WHERE origin = :origin AND resource IN (:resource1, :resource2))`.
    func observeEtagsExist(
        origin: String,
        resource1: String,
        resource2: String
    ) -> AsyncValueObservation<Bool> {
        ValueObservation
            .tracking { db in
                try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM sync_meta WHERE origin = ? AND resource IN (?, ?))",
                    arguments: [origin, resource1, resource2]
                ) ?? false
            }
            .values(in: dbWriter)
    }

    func upsert(_ meta: SyncMeta) async throws {
        try await dbWriter.write { db in
            try meta.upsert(db)
        }
    }

    /// Сбрасывает сохранённый ETag — инвалидация кэша другого origin для ресурса.
    func deleteEtag(origin: String, resource: String) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "DELETE FROM sync_meta WHERE origin = ? AND resource = ?",
                arguments: [origin, resource]
            )
        }
    }
}
