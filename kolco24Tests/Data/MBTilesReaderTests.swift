//
//  MBTilesReaderTests.swift
//  kolco24Tests
//
//  Тесты `MBTilesReader` на крошечном `.mbtiles`-фикстуре, собранном прямо в
//  тесте через GRDB в temp-каталоге (write-режим), затем открытом читателем
//  (read-only). Проверяем: корректность y-flip (вставка по TMS-строке, чтение
//  по XYZ-y), отсутствующий тайл → nil, парсинг metadata, бросок init на
//  несуществующем файле.
//

import Foundation
import GRDB
import Testing
@testable import kolco24

struct MBTilesReaderTests {

    /// Собрать `.mbtiles`-фикстуру в temp-каталоге и вернуть путь. Таблицы
    /// `tiles`/`metadata` как в стандарте MBTiles; тайлы вставляются по TMS-строке.
    private func makeFixture(
        tiles: [(z: Int, x: Int, tmsRow: Int, data: Data)],
        metadata: [(String, String)]
    ) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mbtiles-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("fixture.mbtiles").path

        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB)")
            try db.execute(sql: "CREATE TABLE metadata (name TEXT, value TEXT)")
            for t in tiles {
                try db.execute(
                    sql: "INSERT INTO tiles (zoom_level, tile_column, tile_row, tile_data) VALUES (?, ?, ?, ?)",
                    arguments: [t.z, t.x, t.tmsRow, t.data]
                )
            }
            for m in metadata {
                try db.execute(
                    sql: "INSERT INTO metadata (name, value) VALUES (?, ?)",
                    arguments: [m.0, m.1]
                )
            }
        }
        // Закрыть write-соединение перед открытием read-only.
        try queue.close()
        return path
    }

    @Test func readsExistingTileWithCorrectYFlip() throws {
        // XYZ y = 1 at z = 2 → TMS row = 2^2 − 1 − 1 = 2.
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let path = try makeFixture(
            tiles: [(z: 2, x: 3, tmsRow: 2, data: payload)],
            metadata: []
        )
        let reader = try MBTilesReader(path: path)
        let data = reader.tileData(z: 2, x: 3, y: 1)
        #expect(data == payload)
    }

    @Test func missingTileReturnsNil() throws {
        let path = try makeFixture(
            tiles: [(z: 2, x: 3, tmsRow: 2, data: Data([0x01]))],
            metadata: []
        )
        let reader = try MBTilesReader(path: path)
        #expect(reader.tileData(z: 5, x: 5, y: 5) == nil)
    }

    @Test func parsesMetadata() throws {
        let path = try makeFixture(
            tiles: [],
            metadata: [
                ("bounds", "37.0,55.0,38.0,56.0"),
                ("minzoom", "8"),
                ("maxzoom", "15"),
            ]
        )
        let reader = try MBTilesReader(path: path)
        let meta = reader.metadata()
        #expect(meta?.bounds?.w == 37.0)
        #expect(meta?.bounds?.n == 56.0)
        #expect(meta?.minZoom == 8)
        #expect(meta?.maxZoom == 15)
    }

    @Test func nonexistentFileThrows() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).mbtiles").path
        #expect(throws: (any Error).self) {
            _ = try MBTilesReader(path: missing)
        }
    }

    /// Битый/пустой `.mbtiles`: валидный sqlite, но без таблиц `tiles`/`metadata`.
    /// `init` открывается (это sqlite), а `tileData`/`metadata` ловят SQL-ошибку
    /// «no such table» → `nil` (never-throw, карта пустая, но не крэш).
    @Test func corruptFileMissingTablesReturnsNilNeverThrows() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mbtiles-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("empty.mbtiles").path
        // Валидный sqlite-файл без ожидаемых таблиц.
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE unrelated (x INTEGER)")
        }
        try queue.close()

        let reader = try MBTilesReader(path: path)
        #expect(reader.tileData(z: 2, x: 3, y: 1) == nil)
        #expect(reader.metadata() == nil)
    }
}
