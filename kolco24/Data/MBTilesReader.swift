//
//  MBTilesReader.swift
//  kolco24
//
//  Read-only чтение растровых тайлов и метаданных из `.mbtiles` (sqlite) через
//  GRDB. `import GRDB` живёт только под `Data/` (grep-инвариант). Y-flip TMS и
//  парсинг метаданных — из `Core/Map/MBTiles.swift` (Foundation-only); здесь
//  только сам доступ к файлу.
//
//  Конкурентность: `MKTileOverlay.loadTile` зовётся конкурентно с нескольких
//  потоков MapKit. Один `DatabaseQueue` сериализует чтения через одно
//  соединение — для pan/zoom растровых тайлов этого достаточно. Read-only файл
//  всё равно нельзя открыть WAL-`DatabasePool` (WAL требует записи), поэтому
//  `DatabaseQueue` с `readonly = true` — единственный вариант.
//

import Foundation
import GRDB
import os

private let mbtilesLog = Logger(subsystem: "kolco24", category: "MBTilesReader")

/// Read-only читатель `.mbtiles`. Чтения never-throw (отсутствующий тайл/битая
/// таблица → `nil` + лог); бросает только `init`, если файл нельзя открыть.
struct MBTilesReader {
    private let dbQueue: DatabaseQueue

    /// Открыть `.mbtiles` в режиме только-для-чтения.
    /// - Throws: ошибку GRDB, если файла нет или он не sqlite.
    init(path: String) throws {
        var config = Configuration()
        config.readonly = true
        dbQueue = try DatabaseQueue(path: path, configuration: config)
    }

    /// Похоже ли содержимое на валидный MBTiles: есть запрашиваемое отношение `tiles`
    /// и в нём хотя бы один тайл. Читаемый sqlite без `tiles` (или с пустым) — НЕ
    /// пригодная подложка: с `canReplaceMapContent = true` каждый тайл был бы
    /// прозрачным и Apple-подложка подавлена → пустая карта без ретрая. Вызывающий
    /// (`OverlayCache`) при `false` не строит дескриптор — карта деградирует в онлайн
    /// Apple-подложку.
    ///
    /// Проверка схемо-агностична: сам `SELECT 1 FROM tiles LIMIT 1` несёт проверку —
    /// `tiles` по стандарту MBTiles 1.3 может быть как таблицей, так и VIEW поверх
    /// нормализованных `map`+`images` (так делают mb-util/MapTiler/GDAL/tilelive);
    /// `tableExists`-предпроверка ложно отвергала бы view-схему. Отсутствие отношения
    /// `tiles` → SQL-ошибка → перехват → `false`; пустое отношение → `false`.
    /// Never-throw: любая ошибка → `false`. Дёшево (`LIMIT 1`).
    func looksLikeValidMBTiles() -> Bool {
        do {
            return try dbQueue.read { db in
                try Bool.fetchOne(db, sql: "SELECT 1 FROM tiles LIMIT 1") ?? false
            }
        } catch {
            mbtilesLog.error("validity check failed: \(error)")
            return false
        }
    }

    /// Данные тайла по XYZ-координатам. Внутри — TMS-флип строки (`tmsRow`).
    /// Отсутствующий тайл или ошибка чтения → `nil` (never-throw).
    func tileData(z: Int, x: Int, y: Int) -> Data? {
        let row = tmsRow(z: z, y: y)
        do {
            return try dbQueue.read { db in
                try Data.fetchOne(
                    db,
                    sql: "SELECT tile_data FROM tiles "
                        + "WHERE zoom_level = ? AND tile_column = ? AND tile_row = ?",
                    arguments: [z, x, row]
                )
            }
        } catch {
            mbtilesLog.error("tileData read failed z=\(z) x=\(x) y=\(y): \(error)")
            return nil
        }
    }

    /// Распарсенные метаданные из таблицы `metadata`. Битая/отсутствующая
    /// таблица → `nil` (never-throw).
    func metadata() -> MBTilesMetadata? {
        do {
            let raw = try dbQueue.read { db -> [String: String] in
                let rows = try Row.fetchAll(db, sql: "SELECT name, value FROM metadata")
                var dict: [String: String] = [:]
                for r in rows {
                    if let name: String = r["name"], let value: String = r["value"] {
                        dict[name] = value
                    }
                }
                return dict
            }
            return parseMBTilesMetadata(raw)
        } catch {
            mbtilesLog.error("metadata read failed: \(error)")
            return nil
        }
    }
}
