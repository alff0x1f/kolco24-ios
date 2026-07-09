//
//  JudgeScanStore.swift
//  kolco24
//
//  Порт `data/db/JudgeScanDao.kt` (этап 2): судейские пики старта/финиша и их
//  дренаж загрузки. Строки **write-once** — нет version-guard'а `updatedAt`
//  (в отличие от `MarkStore.markUploaded*IfUnchanged`). Скоуп — `raceId` только
//  (судейская станция сканит все команды гонки). `@Insert` → `insert(db)`,
//  `Flow` → `ValueObservation…values`, `suspend` → `async throws`.
//
//  Вспомогательный тип `UploadCounts` — общий с `MarkStore`/`TrackStore`,
//  живёт в `UploadTypes.swift`.
//

import Foundation
import GRDB

struct JudgeScanStore {
    let dbWriter: any DatabaseWriter

    init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    // MARK: - Запись

    func insert(_ scan: JudgeScan) async throws {
        try await dbWriter.write { db in
            try scan.insert(db)
        }
    }

    // MARK: - Дренаж загрузки

    /// Кандидаты на загрузку для одного таргета (local), скоуп `raceId`. Явное `= ?` —
    /// голое `WHERE raceId` читается как truthy-выражение и ломает фильтр скоупа.
    func unuploadedLocal(raceId: Int, limit: Int) async throws -> [JudgeScan] {
        try await dbWriter.read { db in
            try JudgeScan.fetchAll(
                db,
                sql: "SELECT * FROM judge_scans WHERE raceId = ? AND uploadedLocal = 0 "
                    + "ORDER BY COALESCE(trustedTakenAt, takenAt), id LIMIT ?",
                arguments: [raceId, limit]
            )
        }
    }

    func unuploadedCloud(raceId: Int, limit: Int) async throws -> [JudgeScan] {
        try await dbWriter.read { db in
            try JudgeScan.fetchAll(
                db,
                sql: "SELECT * FROM judge_scans WHERE raceId = ? AND uploadedCloud = 0 "
                    + "ORDER BY COALESCE(trustedTakenAt, takenAt), id LIMIT ?",
                arguments: [raceId, limit]
            )
        }
    }

    func markUploadedLocal(ids: [String]) async throws {
        try await dbWriter.write { db in
            try db.execute(literal: "UPDATE judge_scans SET uploadedLocal = 1 WHERE id IN \(ids)")
        }
    }

    func markUploadedCloud(ids: [String]) async throws {
        try await dbWriter.write { db in
            try db.execute(literal: "UPDATE judge_scans SET uploadedCloud = 1 WHERE id IN \(ids)")
        }
    }

    /// Каждая гонка, у которой есть скан, не доставленный хотя бы одному таргету.
    func pendingUploadRaces() async throws -> [Int] {
        try await dbWriter.read { db in
            try Int.fetchAll(
                db,
                sql: "SELECT DISTINCT raceId FROM judge_scans WHERE uploadedLocal = 0 OR uploadedCloud = 0"
            )
        }
    }

    // MARK: - Агрегат прогресса загрузки

    /// Зеркало `MarkDao.uploadCountsMetadata` без `teamId` (судейские сканы raceId-only).
    /// Дословный CASE, `COALESCE(...,0)` гасит NULL пустого скоупа.
    func uploadCounts(raceId: Int) -> AsyncValueObservation<UploadCounts> {
        ValueObservation
            .tracking { db in
                try UploadCounts.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) AS total, "
                        + "COALESCE(SUM(CASE WHEN uploadedLocal THEN 1 ELSE 0 END), 0) AS local, "
                        + "COALESCE(SUM(CASE WHEN uploadedCloud THEN 1 ELSE 0 END), 0) AS cloud "
                        + "FROM judge_scans WHERE raceId = ?",
                    arguments: [raceId]
                ) ?? UploadCounts(total: 0, local: 0, cloud: 0)
            }
            .values(in: dbWriter)
    }
}
