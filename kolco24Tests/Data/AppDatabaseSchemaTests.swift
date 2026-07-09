//
//  AppDatabaseSchemaTests.swift
//  kolco24Tests
//
//  Snapshot-тест схемы `"v1"` — замена Android `MigrationTest` (мигрировать нечего,
//  iOS-база рождается сразу в финальной схеме Room v5). Сверяет инвентарь
//  таблиц/колонок/индексов/PK, транскрибированный дословно из
//  `app/schemas/ru.kolco24.kolco24.data.db.AppDatabase/5.json`, с тем, что реально
//  создаёт миграция. Любое расхождение (тип, nullability, лишний SQL-`DEFAULT`,
//  забытый индекс, порядок композитного PK) валит тест.
//

import GRDB
import Testing
@testable import kolco24

struct AppDatabaseSchemaTests {

    // MARK: - Ожидаемая схема (транскрипция 5.json)

    /// Колонка: имя, тип-аффинность, notnull, позиция в PK (0 — не PK, иначе 1-based).
    private struct Col {
        let name: String
        let type: String
        let notNull: Bool
        let pk: Int
        init(_ name: String, _ type: String, notNull: Bool, pk: Int = 0) {
            self.name = name
            self.type = type
            self.notNull = notNull
            self.pk = pk
        }
    }

    private struct TableSpec {
        let name: String
        let columns: [Col]
        /// Ожидаемые индексы: имя → колонки.
        let indices: [String: [String]]
    }

    private static let expected: [TableSpec] = [
        TableSpec(name: "races", columns: [
            Col("id", "INTEGER", notNull: true, pk: 1),
            Col("name", "TEXT", notNull: true),
            Col("slug", "TEXT", notNull: true),
            Col("date", "TEXT", notNull: true),
            Col("dateEnd", "TEXT", notNull: false),
            Col("place", "TEXT", notNull: true),
            Col("regStatus", "TEXT", notNull: true),
        ], indices: [:]),

        TableSpec(name: "sync_meta", columns: [
            Col("origin", "TEXT", notNull: true, pk: 1),
            Col("resource", "TEXT", notNull: true, pk: 2),
            Col("etag", "TEXT", notNull: true),
        ], indices: [:]),

        TableSpec(name: "categories", columns: [
            Col("id", "INTEGER", notNull: true, pk: 1),
            Col("raceId", "INTEGER", notNull: true),
            Col("code", "TEXT", notNull: true),
            Col("shortName", "TEXT", notNull: true),
            Col("name", "TEXT", notNull: true),
            Col("sortOrder", "INTEGER", notNull: true),
        ], indices: [:]),

        TableSpec(name: "teams", columns: [
            Col("id", "INTEGER", notNull: true, pk: 1),
            Col("raceId", "INTEGER", notNull: true),
            Col("teamname", "TEXT", notNull: true),
            Col("startNumber", "TEXT", notNull: false),
            Col("categoryId", "INTEGER", notNull: false),
            Col("ucount", "INTEGER", notNull: true),
            Col("paidPeople", "REAL", notNull: true),
            Col("startTime", "INTEGER", notNull: true),
            Col("finishTime", "INTEGER", notNull: true),
            Col("members", "TEXT", notNull: true),
        ], indices: ["index_teams_raceId": ["raceId"]]),

        TableSpec(name: "selected_team", columns: [
            Col("id", "INTEGER", notNull: true, pk: 1),
            Col("raceId", "INTEGER", notNull: true),
            Col("teamId", "INTEGER", notNull: true),
        ], indices: [:]),

        TableSpec(name: "checkpoints", columns: [
            Col("id", "INTEGER", notNull: true, pk: 1),
            Col("raceId", "INTEGER", notNull: true),
            Col("number", "INTEGER", notNull: true),
            Col("cost", "INTEGER", notNull: false),
            Col("type", "TEXT", notNull: true),
            Col("description", "TEXT", notNull: false),
            Col("locked", "INTEGER", notNull: true),
            Col("encIv", "TEXT", notNull: false),
            Col("encCt", "TEXT", notNull: false),
            Col("color", "TEXT", notNull: true),
        ], indices: ["index_checkpoints_raceId": ["raceId"]]),

        TableSpec(name: "tags", columns: [
            Col("raceId", "INTEGER", notNull: true, pk: 1),
            Col("bid", "TEXT", notNull: true, pk: 2),
            Col("checkpointId", "INTEGER", notNull: true),
            Col("checkMethod", "TEXT", notNull: true),
            Col("iv", "TEXT", notNull: false),
            Col("ct", "TEXT", notNull: false),
        ], indices: [
            "index_tags_raceId": ["raceId"],
            "index_tags_checkpointId": ["checkpointId"],
        ]),

        TableSpec(name: "member_tags", columns: [
            Col("raceId", "INTEGER", notNull: true, pk: 1),
            Col("nfcUid", "TEXT", notNull: true, pk: 2),
            Col("number", "INTEGER", notNull: true),
        ], indices: ["index_member_tags_raceId": ["raceId"]]),

        TableSpec(name: "member_chip_bindings", columns: [
            Col("teamId", "INTEGER", notNull: true, pk: 1),
            Col("numberInTeam", "INTEGER", notNull: true, pk: 2),
            Col("nfcUid", "TEXT", notNull: true),
            Col("participantNumber", "INTEGER", notNull: true),
        ], indices: ["index_member_chip_bindings_nfcUid": ["nfcUid"]]),

        TableSpec(name: "marks", columns: [
            Col("id", "TEXT", notNull: true, pk: 1),
            Col("raceId", "INTEGER", notNull: true),
            Col("teamId", "INTEGER", notNull: true),
            Col("checkpointId", "INTEGER", notNull: true),
            Col("checkpointNumber", "INTEGER", notNull: true),
            Col("cost", "INTEGER", notNull: true),
            Col("method", "TEXT", notNull: true),
            Col("cpUid", "TEXT", notNull: true),
            Col("cpCode", "TEXT", notNull: true),
            Col("present", "TEXT", notNull: true),
            Col("presentDetails", "TEXT", notNull: false),
            Col("expectedCount", "INTEGER", notNull: true),
            Col("complete", "INTEGER", notNull: true),
            Col("photoPath", "TEXT", notNull: false),
            Col("takenAt", "INTEGER", notNull: true),
            Col("updatedAt", "INTEGER", notNull: true),
            Col("uploadedLocal", "INTEGER", notNull: true),
            Col("uploadedCloud", "INTEGER", notNull: true),
            Col("photosUploadedLocal", "INTEGER", notNull: true),
            Col("photosUploadedCloud", "INTEGER", notNull: true),
            Col("trustedTakenAt", "INTEGER", notNull: false),
            Col("elapsedRealtimeAt", "INTEGER", notNull: false),
            Col("bootCount", "INTEGER", notNull: false),
            Col("locLat", "REAL", notNull: false),
            Col("locLon", "REAL", notNull: false),
            Col("locAccuracy", "REAL", notNull: false),
            Col("locAltitude", "REAL", notNull: false),
            Col("locVerticalAccuracy", "REAL", notNull: false),
            Col("locGpsTimeMs", "INTEGER", notNull: false),
            Col("locElapsedRealtimeAt", "INTEGER", notNull: false),
        ], indices: [
            "index_marks_teamId": ["teamId"],
            "index_marks_checkpointId": ["checkpointId"],
            "index_marks_raceId": ["raceId"],
        ]),

        TableSpec(name: "legend_meta", columns: [
            Col("raceId", "INTEGER", notNull: true, pk: 1),
            Col("totalCost", "INTEGER", notNull: true),
            Col("scoringCount", "INTEGER", notNull: true),
        ], indices: [:]),

        TableSpec(name: "track_points", columns: [
            Col("id", "TEXT", notNull: true, pk: 1),
            Col("raceId", "INTEGER", notNull: true),
            Col("teamId", "INTEGER", notNull: true),
            Col("lat", "REAL", notNull: true),
            Col("lon", "REAL", notNull: true),
            Col("accuracy", "REAL", notNull: true),
            Col("altitude", "REAL", notNull: false),
            Col("verticalAccuracyMeters", "REAL", notNull: false),
            Col("gpsTimeMs", "INTEGER", notNull: true),
            Col("elapsedRealtimeAt", "INTEGER", notNull: true),
            Col("bootCount", "INTEGER", notNull: false),
            Col("wallMs", "INTEGER", notNull: true),
            Col("trustedMs", "INTEGER", notNull: false),
            Col("segmentId", "TEXT", notNull: true),
            Col("uploadedLocal", "INTEGER", notNull: true),
            Col("uploadedCloud", "INTEGER", notNull: true),
        ], indices: [
            "index_track_points_teamId": ["teamId"],
            "index_track_points_raceId": ["raceId"],
        ]),

        TableSpec(name: "judge_scans", columns: [
            Col("id", "TEXT", notNull: true, pk: 1),
            Col("raceId", "INTEGER", notNull: true),
            Col("eventType", "TEXT", notNull: true),
            Col("participantNumber", "INTEGER", notNull: true),
            Col("nfcUid", "TEXT", notNull: true),
            Col("takenAt", "INTEGER", notNull: true),
            Col("trustedTakenAt", "INTEGER", notNull: false),
            Col("elapsedRealtimeAt", "INTEGER", notNull: true),
            Col("bootCount", "INTEGER", notNull: false),
            Col("sourceInstallId", "TEXT", notNull: true),
            Col("uploadedLocal", "INTEGER", notNull: true),
            Col("uploadedCloud", "INTEGER", notNull: true),
        ], indices: ["index_judge_scans_raceId": ["raceId"]]),
    ]

    // MARK: - Тесты

    @Test func migrationRunsOnEmptyDatabase() throws {
        // Не должно бросить: миграция "v1" отрабатывает на пустой базе.
        let db = try AppDatabase.makeInMemory()
        let applied = try db.writer.read { try AppDatabase.migrator.appliedMigrations($0) }
        #expect(applied == ["v1"])
    }

    @Test func tableInventoryMatchesRoomSchema() throws {
        let db = try AppDatabase.makeInMemory()
        let actualTables = try db.writer.read { database -> Set<String> in
            let names = try String.fetchAll(database, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                  AND name != 'grdb_migrations'
                """)
            return Set(names)
        }
        let expectedTables = Set(Self.expected.map(\.name))
        #expect(actualTables == expectedTables)
    }

    @Test func columnInventoryMatchesRoomSchema() throws {
        let db = try AppDatabase.makeInMemory()
        for spec in Self.expected {
            try db.writer.read { database in
                let rows = try Row.fetchAll(database, sql: "PRAGMA table_info(\(spec.name))")
                #expect(rows.count == spec.columns.count, "column count mismatch in \(spec.name)")
                // PRAGMA table_info идёт по cid — порядок объявления колонок.
                for (row, col) in zip(rows, spec.columns) {
                    let name: String = row["name"]
                    let type: String = row["type"]
                    let notNull: Int = row["notnull"]
                    let pk: Int = row["pk"]
                    let dflt: DatabaseValue = row["dflt_value"]
                    #expect(name == col.name, "\(spec.name): column name")
                    #expect(type == col.type, "\(spec.name).\(col.name): type")
                    #expect((notNull == 1) == col.notNull, "\(spec.name).\(col.name): notnull")
                    #expect(pk == col.pk, "\(spec.name).\(col.name): pk position")
                    // Инвариант плана: ни одного SQL-DEFAULT в схеме v1.
                    #expect(dflt.isNull, "\(spec.name).\(col.name): unexpected SQL DEFAULT")
                }
            }
        }
    }

    @Test func indexInventoryMatchesRoomSchema() throws {
        let db = try AppDatabase.makeInMemory()
        for spec in Self.expected {
            try db.writer.read { database in
                // Только явно созданные индексы (origin 'c'); авто-индексы PK ('pk') пропускаем.
                let indexRows = try Row.fetchAll(database, sql: "PRAGMA index_list(\(spec.name))")
                var actual: [String: [String]] = [:]
                for row in indexRows {
                    let origin: String = row["origin"]
                    guard origin == "c" else { continue }
                    let indexName: String = row["name"]
                    let unique: Int = row["unique"]
                    #expect(unique == 0, "\(spec.name).\(indexName): expected non-unique index")
                    let cols = try Row.fetchAll(database, sql: "PRAGMA index_info(\(indexName))")
                        .map { $0["name"] as String }
                    actual[indexName] = cols
                }
                #expect(actual == spec.indices, "index inventory mismatch in \(spec.name)")
            }
        }
    }
}
