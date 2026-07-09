//
//  CheckpointStore.swift
//  kolco24
//
//  Store-структура над таблицей `checkpoints` — порт `data/db/CheckpointDao.kt`
//  (этап 2). `@Insert(REPLACE)` → `.replace`. `@Transaction replaceAllForRace`
//  сохраняет предыдущие оффлайн-раскрытия (preserve-reveal, вариант A): refresh
//  не должен снова залочить КП, который пользователь уже раскрыл оффлайн.
//

import GRDB

struct CheckpointStore {
    let dbWriter: any DatabaseWriter

    init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    /// `SELECT * FROM checkpoints WHERE raceId = :raceId ORDER BY number, id`.
    func observeCheckpointsForRace(_ raceId: Int) -> AsyncValueObservation<[Checkpoint]> {
        ValueObservation
            .tracking { db in
                try Checkpoint.fetchAll(
                    db,
                    sql: "SELECT * FROM checkpoints WHERE raceId = ? ORDER BY number, id",
                    arguments: [raceId]
                )
            }
            .values(in: dbWriter)
    }

    func insertCheckpoints(_ checkpoints: [Checkpoint]) async throws {
        try await dbWriter.write { db in
            for checkpoint in checkpoints {
                try checkpoint.insert(db, onConflict: .replace)
            }
        }
    }

    func deleteCheckpointsForRace(_ raceId: Int) async throws {
        try await dbWriter.write { db in
            try db.execute(sql: "DELETE FROM checkpoints WHERE raceId = ?", arguments: [raceId])
        }
    }

    /// Снимок раскрытых (non-null `cost`) строк гонки — сохранить открытый контент
    /// при resync, не залочив его снова.
    func revealedForRace(_ raceId: Int) async throws -> [Checkpoint] {
        try await dbWriter.read { db in
            try Checkpoint.fetchAll(
                db,
                sql: "SELECT * FROM checkpoints WHERE raceId = ? AND cost IS NOT NULL",
                arguments: [raceId]
            )
        }
    }

    /// Записать открытый текст оффлайн-раскрытого КП и пометить строку раскрытой.
    func reveal(id: Int, cost: Int, description: String?) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE checkpoints SET cost = ?, description = ?, locked = 0 WHERE id = ?",
                arguments: [cost, description, id]
            )
        }
    }

    /// Разовый снимок всех КП гонки — для point-in-time чтений (например, крипто).
    func getCheckpointsForRace(_ raceId: Int) async throws -> [Checkpoint] {
        try await dbWriter.read { db in
            try Checkpoint.fetchAll(
                db,
                sql: "SELECT * FROM checkpoints WHERE raceId = ? ORDER BY number, id",
                arguments: [raceId]
            )
        }
    }

    /// Полная замена КП одной гонки на `200`, **сохраняя прежние раскрытия** (вариант A):
    /// refresh не должен снова залочить КП, который пользователь раскрыл оффлайн. В одной
    /// транзакции: снимок прежних `cost`/`description` раскрытых строк → wipe+re-insert
    /// серверных строк → к каждой входящей всё ещё `locked`-строке, чей id был раскрыт,
    /// re-apply открытый текст. Открытые строки приходят с контентом и перезаписываются
    /// начисто.
    func replaceAllForRace(raceId: Int, checkpoints: [Checkpoint]) async throws {
        try await dbWriter.write { db in
            let previouslyRevealed = try Checkpoint.fetchAll(
                db,
                sql: "SELECT * FROM checkpoints WHERE raceId = ? AND cost IS NOT NULL",
                arguments: [raceId]
            )
            let revealedById = Dictionary(previouslyRevealed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

            try db.execute(sql: "DELETE FROM checkpoints WHERE raceId = ?", arguments: [raceId])
            for checkpoint in checkpoints {
                try checkpoint.insert(db, onConflict: .replace)
            }

            for incoming in checkpoints where incoming.locked {
                guard let prior = revealedById[incoming.id], let cost = prior.cost else { continue }
                try db.execute(
                    sql: "UPDATE checkpoints SET cost = ?, description = ?, locked = 0 WHERE id = ?",
                    arguments: [cost, prior.description, incoming.id]
                )
            }
        }
    }
}
