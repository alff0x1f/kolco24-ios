//
//  AppDatabase.swift
//  kolco24
//
//  Слой данных на GRDB — аналог Android `data/db/AppDatabase.kt` (Room v5).
//  Держит `any DatabaseWriter` + `DatabaseMigrator` с единственной миграцией `"v1"`:
//  снимок финальной схемы Room v5 (`schemas/…/5.json`). Историю Room-миграций
//  1→5 не повторяем — iOS-база рождается сразу в финальной схеме.
//
//  Порт-инвариант: имена таблиц/колонок 1:1 с Room v5 (camelCase-колонки), SQL из
//  DAO переносится дословно. FK нет нигде — связи по id в запросах (см. план этапа 2).
//  В `createSql` из `5.json` НЕТ ни одного SQL-`DEFAULT` (Room не сворачивает
//  промежуточные `ALTER TABLE … DEFAULT 0` обратно в экспортированную схему) —
//  дефолты живут в Swift-инициализаторах `Model/`-типов, не в DDL.
//

import Foundation
import GRDB

/// Точка входа в базу данных. Оборачивает `DatabaseWriter` и прогоняет миграции.
struct AppDatabase {
    /// Пул/очередь GRDB. `DatabasePool` (WAL) для приложения, `DatabaseQueue` для тестов.
    let writer: any DatabaseWriter

    /// Открыть базу поверх готового writer'а и прогнать миграции.
    /// - Throws: ошибку GRDB, если миграция не отработала.
    init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    // MARK: - Фабрики

    /// Продовая база: `DatabasePool` (WAL), файл `kolco24.db` в Application Support.
    /// Каталог создаётся при необходимости (аналог Room `databaseBuilder(…, "kolco24.db")`).
    static func makeShared() throws -> AppDatabase {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let dbURL = appSupport.appendingPathComponent("kolco24.db")
        let pool = try DatabasePool(path: dbURL.path) // GRDB включает WAL по умолчанию
        return try AppDatabase(pool)
    }

    /// In-memory база для тестов: `DatabaseQueue()`.
    static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }

    // MARK: - Очистка данных

    /// Полное имя всех 13 таблиц схемы Room v5 (инвентарь из миграции `"v1"`). Сверяется с реальным
    /// набором таблиц из `sqlite_master` в `AppDatabaseWipeTests` — забытая здесь таблица (добавленная
    /// в схему, но не сюда) валит тест, иначе `wipeAllTables` молча оставил бы в ней строки. Порядок
    /// неважен — FK нет нигде.
    static let allTableNames: [String] = [
        "races",
        "sync_meta",
        "categories",
        "teams",
        "selected_team",
        "checkpoints",
        "tags",
        "member_tags",
        "member_chip_bindings",
        "marks",
        "legend_meta",
        "track_points",
        "judge_scans",
    ]

    /// Очистить все таблицы (`DELETE FROM …`) одной транзакцией — «Очистить базу
    /// данных» из скрытой отладки этапа 9. Схема остаётся жить (не erase+remigrate
    /// в рантайме): после вызова таблицы пусты, но структура цела.
    func wipeAllTables() async throws {
        try await writer.write { db in
            for table in Self.allTableNames {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }

    // MARK: - Миграции

    /// Единственная миграция `"v1"` — снимок схемы Room v5 (все 13 таблиц + индексы).
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // races
            try db.execute(sql: """
                CREATE TABLE races (\
                `id` INTEGER NOT NULL, \
                `name` TEXT NOT NULL, \
                `slug` TEXT NOT NULL, \
                `date` TEXT NOT NULL, \
                `dateEnd` TEXT, \
                `place` TEXT NOT NULL, \
                `regStatus` TEXT NOT NULL, \
                PRIMARY KEY(`id`))
                """)

            // sync_meta
            try db.execute(sql: """
                CREATE TABLE sync_meta (\
                `origin` TEXT NOT NULL, \
                `resource` TEXT NOT NULL, \
                `etag` TEXT NOT NULL, \
                PRIMARY KEY(`origin`, `resource`))
                """)

            // categories
            try db.execute(sql: """
                CREATE TABLE categories (\
                `id` INTEGER NOT NULL, \
                `raceId` INTEGER NOT NULL, \
                `code` TEXT NOT NULL, \
                `shortName` TEXT NOT NULL, \
                `name` TEXT NOT NULL, \
                `sortOrder` INTEGER NOT NULL, \
                PRIMARY KEY(`id`))
                """)

            // teams
            try db.execute(sql: """
                CREATE TABLE teams (\
                `id` INTEGER NOT NULL, \
                `raceId` INTEGER NOT NULL, \
                `teamname` TEXT NOT NULL, \
                `startNumber` TEXT, \
                `categoryId` INTEGER, \
                `ucount` INTEGER NOT NULL, \
                `paidPeople` REAL NOT NULL, \
                `startTime` INTEGER NOT NULL, \
                `finishTime` INTEGER NOT NULL, \
                `members` TEXT NOT NULL, \
                PRIMARY KEY(`id`))
                """)
            try db.execute(sql: "CREATE INDEX `index_teams_raceId` ON `teams` (`raceId`)")

            // selected_team
            try db.execute(sql: """
                CREATE TABLE selected_team (\
                `id` INTEGER NOT NULL, \
                `raceId` INTEGER NOT NULL, \
                `teamId` INTEGER NOT NULL, \
                PRIMARY KEY(`id`))
                """)

            // checkpoints
            try db.execute(sql: """
                CREATE TABLE checkpoints (\
                `id` INTEGER NOT NULL, \
                `raceId` INTEGER NOT NULL, \
                `number` INTEGER NOT NULL, \
                `cost` INTEGER, \
                `type` TEXT NOT NULL, \
                `description` TEXT, \
                `locked` INTEGER NOT NULL, \
                `encIv` TEXT, \
                `encCt` TEXT, \
                `color` TEXT NOT NULL, \
                PRIMARY KEY(`id`))
                """)
            try db.execute(sql: "CREATE INDEX `index_checkpoints_raceId` ON `checkpoints` (`raceId`)")

            // tags
            try db.execute(sql: """
                CREATE TABLE tags (\
                `raceId` INTEGER NOT NULL, \
                `bid` TEXT NOT NULL, \
                `checkpointId` INTEGER NOT NULL, \
                `checkMethod` TEXT NOT NULL, \
                `iv` TEXT, \
                `ct` TEXT, \
                PRIMARY KEY(`raceId`, `bid`))
                """)
            try db.execute(sql: "CREATE INDEX `index_tags_raceId` ON `tags` (`raceId`)")
            try db.execute(sql: "CREATE INDEX `index_tags_checkpointId` ON `tags` (`checkpointId`)")

            // member_tags
            try db.execute(sql: """
                CREATE TABLE member_tags (\
                `raceId` INTEGER NOT NULL, \
                `nfcUid` TEXT NOT NULL, \
                `number` INTEGER NOT NULL, \
                PRIMARY KEY(`raceId`, `nfcUid`))
                """)
            try db.execute(sql: "CREATE INDEX `index_member_tags_raceId` ON `member_tags` (`raceId`)")

            // member_chip_bindings
            try db.execute(sql: """
                CREATE TABLE member_chip_bindings (\
                `teamId` INTEGER NOT NULL, \
                `numberInTeam` INTEGER NOT NULL, \
                `nfcUid` TEXT NOT NULL, \
                `participantNumber` INTEGER NOT NULL, \
                PRIMARY KEY(`teamId`, `numberInTeam`))
                """)
            try db.execute(sql: "CREATE INDEX `index_member_chip_bindings_nfcUid` ON `member_chip_bindings` (`nfcUid`)")

            // marks
            try db.execute(sql: """
                CREATE TABLE marks (\
                `id` TEXT NOT NULL, \
                `raceId` INTEGER NOT NULL, \
                `teamId` INTEGER NOT NULL, \
                `checkpointId` INTEGER NOT NULL, \
                `checkpointNumber` INTEGER NOT NULL, \
                `cost` INTEGER NOT NULL, \
                `method` TEXT NOT NULL, \
                `cpUid` TEXT NOT NULL, \
                `cpCode` TEXT NOT NULL, \
                `present` TEXT NOT NULL, \
                `presentDetails` TEXT, \
                `expectedCount` INTEGER NOT NULL, \
                `complete` INTEGER NOT NULL, \
                `photoPath` TEXT, \
                `takenAt` INTEGER NOT NULL, \
                `updatedAt` INTEGER NOT NULL, \
                `uploadedLocal` INTEGER NOT NULL, \
                `uploadedCloud` INTEGER NOT NULL, \
                `photosUploadedLocal` INTEGER NOT NULL, \
                `photosUploadedCloud` INTEGER NOT NULL, \
                `trustedTakenAt` INTEGER, \
                `elapsedRealtimeAt` INTEGER, \
                `bootCount` INTEGER, \
                `locLat` REAL, \
                `locLon` REAL, \
                `locAccuracy` REAL, \
                `locAltitude` REAL, \
                `locVerticalAccuracy` REAL, \
                `locGpsTimeMs` INTEGER, \
                `locElapsedRealtimeAt` INTEGER, \
                PRIMARY KEY(`id`))
                """)
            try db.execute(sql: "CREATE INDEX `index_marks_teamId` ON `marks` (`teamId`)")
            try db.execute(sql: "CREATE INDEX `index_marks_checkpointId` ON `marks` (`checkpointId`)")
            try db.execute(sql: "CREATE INDEX `index_marks_raceId` ON `marks` (`raceId`)")

            // legend_meta
            try db.execute(sql: """
                CREATE TABLE legend_meta (\
                `raceId` INTEGER NOT NULL, \
                `totalCost` INTEGER NOT NULL, \
                `scoringCount` INTEGER NOT NULL, \
                PRIMARY KEY(`raceId`))
                """)

            // track_points
            try db.execute(sql: """
                CREATE TABLE track_points (\
                `id` TEXT NOT NULL, \
                `raceId` INTEGER NOT NULL, \
                `teamId` INTEGER NOT NULL, \
                `lat` REAL NOT NULL, \
                `lon` REAL NOT NULL, \
                `accuracy` REAL NOT NULL, \
                `altitude` REAL, \
                `verticalAccuracyMeters` REAL, \
                `gpsTimeMs` INTEGER NOT NULL, \
                `elapsedRealtimeAt` INTEGER NOT NULL, \
                `bootCount` INTEGER, \
                `wallMs` INTEGER NOT NULL, \
                `trustedMs` INTEGER, \
                `segmentId` TEXT NOT NULL, \
                `uploadedLocal` INTEGER NOT NULL, \
                `uploadedCloud` INTEGER NOT NULL, \
                PRIMARY KEY(`id`))
                """)
            try db.execute(sql: "CREATE INDEX `index_track_points_teamId` ON `track_points` (`teamId`)")
            try db.execute(sql: "CREATE INDEX `index_track_points_raceId` ON `track_points` (`raceId`)")

            // judge_scans
            try db.execute(sql: """
                CREATE TABLE judge_scans (\
                `id` TEXT NOT NULL, \
                `raceId` INTEGER NOT NULL, \
                `eventType` TEXT NOT NULL, \
                `participantNumber` INTEGER NOT NULL, \
                `nfcUid` TEXT NOT NULL, \
                `takenAt` INTEGER NOT NULL, \
                `trustedTakenAt` INTEGER, \
                `elapsedRealtimeAt` INTEGER NOT NULL, \
                `bootCount` INTEGER, \
                `sourceInstallId` TEXT NOT NULL, \
                `uploadedLocal` INTEGER NOT NULL, \
                `uploadedCloud` INTEGER NOT NULL, \
                PRIMARY KEY(`id`))
                """)
            try db.execute(sql: "CREATE INDEX `index_judge_scans_raceId` ON `judge_scans` (`raceId`)")
        }

        return migrator
    }
}
