//
//  TrackStore.swift
//  kolco24
//
//  Порт `data/db/TrackDao.kt` (этап 2): хранение точек GPS-трека и их дренаж
//  загрузки (local wifi + cloud). Сложный SQL сортировок/агрегатов перенесён
//  дословно строкой (см. правило этапа 2). `@Insert(IGNORE)` → `insert(db,
//  onConflict: .ignore)` (повторный UUID не дублируется), `Flow` →
//  `ValueObservation…values`, `suspend` → `async throws`.
//
//  Вспомогательные типы `UploadCounts`/`TrackScope` — общие с
//  `MarkStore`/`JudgeScanStore`, живут в `UploadTypes.swift`.
//

import Foundation
import GRDB

struct TrackStore {
    let dbWriter: any DatabaseWriter

    init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    // MARK: - Observation / чтение

    /// `SELECT * FROM track_points WHERE teamId AND raceId ORDER BY
    /// COALESCE(trustedMs, wallMs), COALESCE(bootCount, -1), elapsedRealtimeAt, id`.
    /// Сортировка по моменту фикса: trusted, если есть, иначе wall; тай-брейк по
    /// boot-сессии и монотонному моменту захвата.
    func observeForTeam(teamId: Int, raceId: Int) -> AsyncValueObservation<[TrackPoint]> {
        ValueObservation
            .tracking { db in
                try TrackPoint.fetchAll(
                    db,
                    sql: "SELECT * FROM track_points WHERE teamId = ? AND raceId = ? "
                        + "ORDER BY COALESCE(trustedMs, wallMs), COALESCE(bootCount, -1), elapsedRealtimeAt, id",
                    arguments: [teamId, raceId]
                )
            }
            .values(in: dbWriter)
    }

    func countForTeam(teamId: Int, raceId: Int) -> AsyncValueObservation<Int> {
        ValueObservation
            .tracking { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM track_points WHERE teamId = ? AND raceId = ?",
                    arguments: [teamId, raceId]
                ) ?? 0
            }
            .values(in: dbWriter)
    }

    /// Per-target прогресс загрузки для одного скоупа. Дословный CASE над Boolean-колонкой
    /// (`SUM(boolean)` хрупок для маппинга), `COALESCE(...,0)` гасит NULL пустого скоупа.
    func uploadCounts(teamId: Int, raceId: Int) -> AsyncValueObservation<UploadCounts> {
        ValueObservation
            .tracking { db in
                try UploadCounts.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) AS total, "
                        + "COALESCE(SUM(CASE WHEN uploadedLocal THEN 1 ELSE 0 END), 0) AS local, "
                        + "COALESCE(SUM(CASE WHEN uploadedCloud THEN 1 ELSE 0 END), 0) AS cloud "
                        + "FROM track_points WHERE teamId = ? AND raceId = ?",
                    arguments: [teamId, raceId]
                ) ?? UploadCounts(total: 0, local: 0, cloud: 0)
            }
            .values(in: dbWriter)
    }

    // MARK: - Запись

    /// Каждая вставка всегда несёт значения upload-флагов, поэтому `onConflict: .ignore`
    /// делает повторно доставленный id (тот же клиентский UUID) идемпотентным.
    func insertAll(_ points: [TrackPoint]) async throws {
        try await dbWriter.write { db in
            for point in points {
                try point.insert(db, onConflict: .ignore)
            }
        }
    }

    func deleteForTeam(teamId: Int, raceId: Int) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "DELETE FROM track_points WHERE teamId = ? AND raceId = ?",
                arguments: [teamId, raceId]
            )
        }
    }

    // MARK: - Дренаж загрузки

    /// Кандидаты на загрузку для одного таргета (local), скоуп `(raceId, teamId)`: батч уходит
    /// в `/race/<raceId>/track/`, поэтому не должен захватывать чужие точки.
    func unuploadedLocal(raceId: Int, teamId: Int, limit: Int) async throws -> [TrackPoint] {
        try await dbWriter.read { db in
            try TrackPoint.fetchAll(
                db,
                sql: "SELECT * FROM track_points WHERE raceId = ? AND teamId = ? "
                    + "AND uploadedLocal = 0 "
                    + "ORDER BY COALESCE(trustedMs, wallMs), COALESCE(bootCount, -1), elapsedRealtimeAt, id "
                    + "LIMIT ?",
                arguments: [raceId, teamId, limit]
            )
        }
    }

    func unuploadedCloud(raceId: Int, teamId: Int, limit: Int) async throws -> [TrackPoint] {
        try await dbWriter.read { db in
            try TrackPoint.fetchAll(
                db,
                sql: "SELECT * FROM track_points WHERE raceId = ? AND teamId = ? "
                    + "AND uploadedCloud = 0 "
                    + "ORDER BY COALESCE(trustedMs, wallMs), COALESCE(bootCount, -1), elapsedRealtimeAt, id "
                    + "LIMIT ?",
                arguments: [raceId, teamId, limit]
            )
        }
    }

    func markUploadedLocal(ids: [String]) async throws {
        try await dbWriter.write { db in
            try db.execute(literal: "UPDATE track_points SET uploadedLocal = 1 WHERE id IN \(ids)")
        }
    }

    func markUploadedCloud(ids: [String]) async throws {
        try await dbWriter.write { db in
            try db.execute(literal: "UPDATE track_points SET uploadedCloud = 1 WHERE id IN \(ids)")
        }
    }

    /// Каждая пара `(raceId, teamId)`, у которой есть точка, не доставленная хотя бы одному
    /// таргету — опортунистический ре-сенд обходит все, не только текущий выбор.
    func pendingUploadScopes() async throws -> [TrackScope] {
        try await dbWriter.read { db in
            try TrackScope.fetchAll(
                db,
                sql: "SELECT DISTINCT raceId, teamId FROM track_points "
                    + "WHERE uploadedLocal = 0 OR uploadedCloud = 0"
            )
        }
    }
}
