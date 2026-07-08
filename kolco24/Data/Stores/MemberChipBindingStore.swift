//
//  MemberChipBindingStore.swift
//  kolco24
//
//  Store-структура над таблицей `member_chip_bindings` (композитный PK
//  `(teamId, numberInTeam)`, индекс по `nfcUid`) — порт
//  `data/db/MemberChipBindingDao.kt` (этап 2). `@Upsert` → `upsert(db)`;
//  `reassign` — одна транзакция deleteByUid→upsert (атомарный перенос браслета,
//  чтобы чип не оказался на двух слотах одновременно).
//

import GRDB

struct MemberChipBindingStore {
    let dbWriter: any DatabaseWriter

    init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    /// `SELECT * FROM member_chip_bindings WHERE teamId = :teamId ORDER BY numberInTeam`.
    func observeForTeam(_ teamId: Int) -> AsyncValueObservation<[MemberChipBinding]> {
        ValueObservation
            .tracking { db in
                try MemberChipBinding.fetchAll(
                    db,
                    sql: "SELECT * FROM member_chip_bindings WHERE teamId = ? ORDER BY numberInTeam",
                    arguments: [teamId]
                )
            }
            .values(in: dbWriter)
    }

    func findByUid(_ nfcUid: String) async throws -> MemberChipBinding? {
        try await dbWriter.read { db in
            try MemberChipBinding.fetchOne(
                db,
                sql: "SELECT * FROM member_chip_bindings WHERE nfcUid = ?",
                arguments: [nfcUid]
            )
        }
    }

    func upsert(_ binding: MemberChipBinding) async throws {
        try await dbWriter.write { db in
            try binding.upsert(db)
        }
    }

    func deleteSlot(teamId: Int, numberInTeam: Int) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "DELETE FROM member_chip_bindings WHERE teamId = ? AND numberInTeam = ?",
                arguments: [teamId, numberInTeam]
            )
        }
    }

    func deleteByUid(_ nfcUid: String) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "DELETE FROM member_chip_bindings WHERE nfcUid = ?",
                arguments: [nfcUid]
            )
        }
    }

    /// Атомарный перенос чипа на новый слот: сбросить любой слот, где сейчас висит
    /// [binding.nfcUid], затем записать [binding] — так чип не оказывается на двух
    /// слотах одновременно. Всё в одной транзакции.
    func reassign(_ binding: MemberChipBinding) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "DELETE FROM member_chip_bindings WHERE nfcUid = ?",
                arguments: [binding.nfcUid]
            )
            try binding.upsert(db)
        }
    }
}
