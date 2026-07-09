//
//  MarkStore.swift
//  kolco24
//
//  Богатейший store слоя данных — порт `data/db/MarkDao.kt` (этап 2): взятия КП,
//  их дренаж загрузки (metadata + frames) и транзакционные read-modify-write
//  (`addMember`, `attachPhotos`). Сложный SQL перенесён дословно строкой (см.
//  правило этапа 2). `@Upsert` → `upsert(db)`; `Flow` → `ValueObservation…values`;
//  `suspend` → `async throws`.
//
//  `MarkDao.attachPhotos` в Kotlin опирается на `data/marks/PhotoPaths.kt`
//  (`photoPaths`/`encodePhotoPaths`/`isSafeRelativePhotoPath`) — в iOS-порте этих
//  хелперов ещё нет, поэтому минимальный эквивалент живёт тут (`MarkPhotoPaths`).
//

import Foundation
import GRDB

/// Кодек и валидатор JSON-списка относительных путей фото в колонке `marks.photoPath`
/// — 1:1 из Kotlin `data/marks/PhotoPaths.kt`. Пути хранятся **относительно** каталога
/// приложения (`marks/<markId>/<uuid>.jpg`); абсолютный путь и любой сегмент `..`
/// отбрасываются (guard от path traversal).
enum MarkPhotoPaths {
    /// JSON-кодирование списка относительных путей; порядок сохраняется.
    /// Делегирует общему `JSONColumnCodec`.
    static func encode(_ paths: [String]) -> String {
        JSONColumnCodec.encode(paths, fallback: "[]")
    }

    /// Декодирование `photoPath`-колонки в список **валидированных** относительных путей.
    /// Никогда не бросает: nil/пусто/битый JSON/не-массив → `[]`. Каждый элемент обязан
    /// иметь форму `marks/<markId>/<uuid>.jpg`; абсолютные пути и `..` отбрасываются.
    static func decode(_ raw: String?) -> [String] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return JSONColumnCodec.decode(raw, as: [String].self, category: "MarkPhotoPaths", fallback: [])
            .filter(isSafeRelativePhotoPath)
    }

    /// `marks/<markId>/<uuid>.jpg`: 3-сегментный относительный путь под `marks/`, без
    /// абсолютного префикса, без `..`, оканчивающийся на `.jpg`. Пустые и состоящие только из
    /// пробелов сегменты отбрасываются (зеркало Kotlin `isBlank()`).
    static func isSafeRelativePhotoPath(_ path: String) -> Bool {
        if isBlank(path) { return false }
        if path.hasPrefix("/") { return false }
        if !path.hasSuffix(".jpg") { return false }
        let segments = path.components(separatedBy: "/")
        if segments.count != 3 { return false }
        if segments.first != "marks" { return false }
        if segments.contains(where: { isBlank($0) || $0 == "." || $0 == ".." }) { return false }
        return true
    }

    /// Зеркало Kotlin `String.isBlank()`: пусто или только whitespace.
    private static func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct MarkStore {
    let dbWriter: any DatabaseWriter

    init(_ dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    // MARK: - Observation / чтение

    /// `SELECT * FROM marks WHERE teamId = :teamId ORDER BY COALESCE(trustedTakenAt, takenAt) DESC`.
    /// Сортировка по scoring/take-времени: trusted, если есть, иначе сырое wall.
    func observeForTeam(_ teamId: Int) -> AsyncValueObservation<[Mark]> {
        ValueObservation
            .tracking { db in
                try Mark.fetchAll(
                    db,
                    sql: "SELECT * FROM marks WHERE teamId = ? ORDER BY COALESCE(trustedTakenAt, takenAt) DESC",
                    arguments: [teamId]
                )
            }
            .values(in: dbWriter)
    }

    func getById(_ id: String) async throws -> Mark? {
        try await dbWriter.read { db in
            try Mark.fetchOne(db, sql: "SELECT * FROM marks WHERE id = ?", arguments: [id])
        }
    }

    /// Все id отметок — для startup-sweep осиротевших фото-папок.
    func allIds() async throws -> [String] {
        try await dbWriter.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM marks")
        }
    }

    func upsert(_ mark: Mark) async throws {
        try await dbWriter.write { db in
            try mark.upsert(db)
        }
    }

    // MARK: - Транзакционные read-modify-write

    /// Добавить одного участника во взятие с set-семантикой (по `numberInTeam`), пересчитать
    /// `complete` против `expectedCount`, bump `updatedAt` и сбросить `uploaded*`. Порт
    /// `MarkDao.addMember`-`@Transaction`. Идемпотентен: если `numberInTeam` уже в `present` —
    /// строка не трогается. Отсутствующая строка — no-op.
    func addMember(
        id: String,
        numberInTeam: Int,
        nfcUid: String?,
        number: Int,
        code: String?,
        now: Int64,
        expectedCount: Int
    ) async throws {
        try await dbWriter.write { db in
            guard let mark = try Mark.fetchOne(db, sql: "SELECT * FROM marks WHERE id = ?", arguments: [id]) else {
                return
            }
            if mark.present.contains(numberInTeam) { return }
            let present = mark.present + [numberInTeam]
            let snapshot = MarkMemberSnapshot(numberInTeam: numberInTeam, nfcUid: nfcUid, number: number, code: code)
            // NULL `presentDetails` (легаси-строка) → пустой список, затем один элемент.
            let presentDetails = (mark.presentDetails ?? []).filter { $0.numberInTeam != numberInTeam } + [snapshot]
            let updated = Mark(
                id: mark.id,
                raceId: mark.raceId,
                teamId: mark.teamId,
                checkpointId: mark.checkpointId,
                checkpointNumber: mark.checkpointNumber,
                cost: mark.cost,
                method: mark.method,
                cpUid: mark.cpUid,
                cpCode: mark.cpCode,
                present: present,
                presentDetails: presentDetails,
                expectedCount: expectedCount,
                complete: expectedCount > 0 && present.count >= expectedCount,
                photoPath: mark.photoPath,
                takenAt: mark.takenAt,
                updatedAt: now,
                // Новый участник мутирует взятие — любая ранее загруженная версия устарела.
                uploadedLocal: false,
                uploadedCloud: false,
                photosUploadedLocal: mark.photosUploadedLocal,
                photosUploadedCloud: mark.photosUploadedCloud,
                trustedTakenAt: mark.trustedTakenAt,
                elapsedRealtimeAt: mark.elapsedRealtimeAt,
                bootCount: mark.bootCount,
                locLat: mark.locLat,
                locLon: mark.locLon,
                locAccuracy: mark.locAccuracy,
                locAltitude: mark.locAltitude,
                locVerticalAccuracy: mark.locVerticalAccuracy,
                locGpsTimeMs: mark.locGpsTimeMs,
                locElapsedRealtimeAt: mark.locElapsedRealtimeAt
            )
            try updated.upsert(db)
        }
    }

    /// Column-scoped UPDATE 7 `loc*`-колонок + сброс `uploaded*`. Порт `MarkDao.attachLocation`.
    /// Никогда не трогает `present`/`complete`/take-времена (гонка с `addMember` в скользящем окне).
    func attachLocation(
        id: String,
        lat: Double,
        lon: Double,
        accuracy: Float?,
        altitude: Double?,
        verticalAccuracy: Float?,
        gpsTimeMs: Int64?,
        elapsedRealtimeAt: Int64
    ) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE marks SET locLat = ?, locLon = ?, locAccuracy = ?, "
                    + "locAltitude = ?, locVerticalAccuracy = ?, "
                    + "locGpsTimeMs = ?, locElapsedRealtimeAt = ?, "
                    + "uploadedLocal = 0, uploadedCloud = 0 WHERE id = ?",
                arguments: [lat, lon, accuracy, altitude, verticalAccuracy, gpsTimeMs, elapsedRealtimeAt, id]
            )
        }
    }

    /// Merge `newPaths` в `photoPath`-JSON, bump `updatedAt`, сброс `photosUploaded*`. Порт
    /// `MarkDao.attachPhotos`-`@Transaction`: читает текущие пути, сливает (distinct, безопасные),
    /// пишет column-scoped **только** `photoPath`/`updatedAt`/`photosUploaded*`. `uploaded*` НЕ
    /// сбрасывается (`photoPath` не часть marks-DTO). Отсутствующая строка — no-op.
    func attachPhotos(id: String, newPaths: [String], now: Int64) async throws {
        try await dbWriter.write { db in
            guard let mark = try Mark.fetchOne(db, sql: "SELECT * FROM marks WHERE id = ?", arguments: [id]) else {
                return
            }
            let existing = MarkPhotoPaths.decode(mark.photoPath)
            let safeNew = newPaths.filter(MarkPhotoPaths.isSafeRelativePhotoPath)
            var merged: [String] = []
            for path in existing + safeNew where !merged.contains(path) {
                merged.append(path)
            }
            try db.execute(
                sql: "UPDATE marks SET photoPath = ?, updatedAt = ?, "
                    + "photosUploadedLocal = 0, photosUploadedCloud = 0 WHERE id = ?",
                arguments: [MarkPhotoPaths.encode(merged), now, id]
            )
        }
    }

    // MARK: - Version-guarded апдейты флагов загрузки

    func markUploadedLocalIfUnchanged(id: String, updatedAt: Int64) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE marks SET uploadedLocal = 1 WHERE id = ? AND updatedAt = ?",
                arguments: [id, updatedAt]
            )
        }
    }

    func markUploadedCloudIfUnchanged(id: String, updatedAt: Int64) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE marks SET uploadedCloud = 1 WHERE id = ? AND updatedAt = ?",
                arguments: [id, updatedAt]
            )
        }
    }

    func markUploadedLocalIfUnchangedAndNoLocation(id: String, updatedAt: Int64) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE marks SET uploadedLocal = 1 WHERE id = ? AND updatedAt = ? AND locLat IS NULL",
                arguments: [id, updatedAt]
            )
        }
    }

    func markUploadedCloudIfUnchangedAndNoLocation(id: String, updatedAt: Int64) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE marks SET uploadedCloud = 1 WHERE id = ? AND updatedAt = ? AND locLat IS NULL",
                arguments: [id, updatedAt]
            )
        }
    }

    func setPhotosUploadedLocalIfUnchanged(id: String, updatedAt: Int64) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE marks SET photosUploadedLocal = 1 WHERE id = ? AND updatedAt = ?",
                arguments: [id, updatedAt]
            )
        }
    }

    func setPhotosUploadedCloudIfUnchanged(id: String, updatedAt: Int64) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: "UPDATE marks SET photosUploadedCloud = 1 WHERE id = ? AND updatedAt = ?",
                arguments: [id, updatedAt]
            )
        }
    }

    // MARK: - Агрегаты прогресса загрузки

    /// Per-target прогресс: фото-строка (`photoPath NOT NULL`) считается uploaded только когда
    /// **И** metadata (`uploadedX`), **И** frames (`photosUploadedX`) доставлены. Дословный CASE.
    func uploadCounts(teamId: Int, raceId: Int) -> AsyncValueObservation<UploadCounts> {
        ValueObservation
            .tracking { db in
                try UploadCounts.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) AS total, "
                        + "COALESCE(SUM(CASE WHEN uploadedLocal AND (photoPath IS NULL OR photosUploadedLocal) "
                        + "THEN 1 ELSE 0 END), 0) AS local, "
                        + "COALESCE(SUM(CASE WHEN uploadedCloud AND (photoPath IS NULL OR photosUploadedCloud) "
                        + "THEN 1 ELSE 0 END), 0) AS cloud "
                        + "FROM marks WHERE teamId = ? AND raceId = ?",
                    arguments: [teamId, raceId]
                ) ?? UploadCounts(total: 0, local: 0, cloud: 0)
            }
            .values(in: dbWriter)
    }

    /// Metadata-only вариант: доехала ли строка взятия до сервера, независимо от кадров.
    func uploadCountsMetadata(teamId: Int, raceId: Int) -> AsyncValueObservation<UploadCounts> {
        ValueObservation
            .tracking { db in
                try UploadCounts.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) AS total, "
                        + "COALESCE(SUM(CASE WHEN uploadedLocal THEN 1 ELSE 0 END), 0) AS local, "
                        + "COALESCE(SUM(CASE WHEN uploadedCloud THEN 1 ELSE 0 END), 0) AS cloud "
                        + "FROM marks WHERE teamId = ? AND raceId = ?",
                    arguments: [teamId, raceId]
                ) ?? UploadCounts(total: 0, local: 0, cloud: 0)
            }
            .values(in: dbWriter)
    }

    /// Сырые frame-флаги каждой фото-несущей строки скоупа — сворачиваются на стороне репозитория.
    func photoFrameRows(teamId: Int, raceId: Int) -> AsyncValueObservation<[PhotoFrameRow]> {
        ValueObservation
            .tracking { db in
                try PhotoFrameRow.fetchAll(
                    db,
                    sql: "SELECT photoPath, photosUploadedLocal, photosUploadedCloud FROM marks "
                        + "WHERE teamId = ? AND raceId = ? AND photoPath IS NOT NULL",
                    arguments: [teamId, raceId]
                )
            }
            .values(in: dbWriter)
    }

    // MARK: - Дренаж загрузки

    /// Кандидаты на загрузку metadata для одного таргета (local). Все строки (complete=true И false)
    /// грузятся; сервер пересчитывает completeness из `present[]`.
    func unuploadedLocal(raceId: Int, teamId: Int, limit: Int) async throws -> [Mark] {
        try await dbWriter.read { db in
            try Mark.fetchAll(
                db,
                sql: "SELECT * FROM marks WHERE raceId = ? AND teamId = ? "
                    + "AND uploadedLocal = 0 "
                    + "ORDER BY COALESCE(trustedTakenAt, takenAt), id "
                    + "LIMIT ?",
                arguments: [raceId, teamId, limit]
            )
        }
    }

    func unuploadedCloud(raceId: Int, teamId: Int, limit: Int) async throws -> [Mark] {
        try await dbWriter.read { db in
            try Mark.fetchAll(
                db,
                sql: "SELECT * FROM marks WHERE raceId = ? AND teamId = ? "
                    + "AND uploadedCloud = 0 "
                    + "ORDER BY COALESCE(trustedTakenAt, takenAt), id "
                    + "LIMIT ?",
                arguments: [raceId, teamId, limit]
            )
        }
    }

    /// Frame-drain кандидаты (local): metadata уже загружена И кадры ещё не приняты И строка несёт кадры.
    func framePendingLocal(raceId: Int, teamId: Int, limit: Int) async throws -> [Mark] {
        try await dbWriter.read { db in
            try Mark.fetchAll(
                db,
                sql: "SELECT * FROM marks WHERE raceId = ? AND teamId = ? "
                    + "AND uploadedLocal = 1 AND photosUploadedLocal = 0 AND photoPath IS NOT NULL "
                    + "ORDER BY COALESCE(trustedTakenAt, takenAt), id "
                    + "LIMIT ?",
                arguments: [raceId, teamId, limit]
            )
        }
    }

    func framePendingCloud(raceId: Int, teamId: Int, limit: Int) async throws -> [Mark] {
        try await dbWriter.read { db in
            try Mark.fetchAll(
                db,
                sql: "SELECT * FROM marks WHERE raceId = ? AND teamId = ? "
                    + "AND uploadedCloud = 1 AND photosUploadedCloud = 0 AND photoPath IS NOT NULL "
                    + "ORDER BY COALESCE(trustedTakenAt, takenAt), id "
                    + "LIMIT ?",
                arguments: [raceId, teamId, limit]
            )
        }
    }

    func markUploadedLocal(ids: [String]) async throws {
        try await dbWriter.write { db in
            try db.execute(literal: "UPDATE marks SET uploadedLocal = 1 WHERE id IN \(ids)")
        }
    }

    func markUploadedCloud(ids: [String]) async throws {
        try await dbWriter.write { db in
            try db.execute(literal: "UPDATE marks SET uploadedCloud = 1 WHERE id IN \(ids)")
        }
    }

    /// Каждая пара `(raceId, teamId)`, у которой есть строка, не доставленная хотя бы одному таргету.
    /// Расширенное условие: metadata-pending **ИЛИ** frame-pending (иначе frame-дренаж не пере-триггерится).
    func pendingUploadScopes() async throws -> [TrackScope] {
        try await dbWriter.read { db in
            try TrackScope.fetchAll(
                db,
                sql: "SELECT DISTINCT raceId, teamId FROM marks "
                    + "WHERE (uploadedLocal = 0 OR uploadedCloud = 0) "
                    + "OR (photoPath IS NOT NULL AND (photosUploadedLocal = 0 OR photosUploadedCloud = 0))"
            )
        }
    }
}
