//
//  LegendMetaStore.swift
//  kolco24
//
//  Store-структура над таблицей `legend_meta` (PK `raceId`) — порт
//  `data/db/LegendMetaDao.kt` (этап 2). `@Upsert` → `upsert(db)`.
//

import GRDB

struct LegendMetaStore {
    let dbWriter: any DatabaseWriter

    init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    /// `SELECT * FROM legend_meta WHERE raceId = :raceId`.
    func observeForRace(_ raceId: Int) -> AsyncValueObservation<LegendMeta?> {
        ValueObservation
            .tracking { db in
                try LegendMeta.fetchOne(
                    db,
                    sql: "SELECT * FROM legend_meta WHERE raceId = ?",
                    arguments: [raceId]
                )
            }
            .values(in: dbWriter)
    }

    /// Наблюдаемая сумма `totalCost` гонки; `0`, пока строки `legend_meta` ещё нет.
    func observeTotalCost(_ raceId: Int) -> AsyncValueObservation<Int> {
        ValueObservation
            .tracking { db in
                try LegendMeta.fetchOne(
                    db,
                    sql: "SELECT * FROM legend_meta WHERE raceId = ?",
                    arguments: [raceId]
                )?.totalCost ?? 0
            }
            .values(in: dbWriter)
    }

    /// Наблюдаемое число зачётных КП (`scoringCount`) гонки; `0`, пока строки `legend_meta` ещё нет.
    func observeScoringCount(_ raceId: Int) -> AsyncValueObservation<Int> {
        ValueObservation
            .tracking { db in
                try LegendMeta.fetchOne(
                    db,
                    sql: "SELECT * FROM legend_meta WHERE raceId = ?",
                    arguments: [raceId]
                )?.scoringCount ?? 0
            }
            .values(in: dbWriter)
    }

    func upsert(_ meta: LegendMeta) async throws {
        try await dbWriter.write { db in
            try meta.upsert(db)
        }
    }
}
