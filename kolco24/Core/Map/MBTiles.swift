//
//  MBTiles.swift
//  kolco24
//
//  Чистая математика формата MBTiles: TMS y-flip и парсинг таблицы `metadata`.
//  Foundation-only (grep-инвариант `Core/Map/` без фреймворков). Главная ловушка
//  формата — строки хранятся в TMS-схеме (`tile_row = 2^z − 1 − y`, где y —
//  XYZ/«гугловский»), поэтому флип живёт здесь, в одном месте, и `MBTilesReader`
//  зовёт его при каждом чтении тайла. Парсинг метаданных never-throw: мусор/
//  пропуски → nil-поля (конвенция stage-2 «decode error → fallback»).
//

import Foundation

/// TMS-флип строки тайла: из XYZ-`y` в MBTiles-`tile_row`. `2^z − 1 − y`.
/// Валидация диапазона входов — забота читателя (`MBTilesReader`); функция чисто
/// арифметическая (для `z = 0` единственный валидный y == 0 → 0; для `z = 15`
/// максимальный y == 2^15 − 1 == 32767 → 0).
func tmsRow(z: Int, y: Int) -> Int {
    return (1 << z) - 1 - y
}

/// Распарсенные метаданные MBTiles. Все поля опциональны — отсутствующий/битый
/// ключ даёт `nil`, а не бросок (never-throw).
struct MBTilesMetadata: Equatable {
    /// Географические границы подложки: W, S, E, N (градусы).
    var bounds: (w: Double, s: Double, e: Double, n: Double)?
    /// Центр карты: lon, lat (+ опционально зум, который здесь игнорируется).
    var center: (lon: Double, lat: Double)?
    var minZoom: Int?
    var maxZoom: Int?

    static func == (lhs: MBTilesMetadata, rhs: MBTilesMetadata) -> Bool {
        boundsEqual(lhs.bounds, rhs.bounds)
            && centerEqual(lhs.center, rhs.center)
            && lhs.minZoom == rhs.minZoom
            && lhs.maxZoom == rhs.maxZoom
    }

    private static func boundsEqual(
        _ a: (w: Double, s: Double, e: Double, n: Double)?,
        _ b: (w: Double, s: Double, e: Double, n: Double)?
    ) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (l?, r?): return l.w == r.w && l.s == r.s && l.e == r.e && l.n == r.n
        default: return false
        }
    }

    private static func centerEqual(
        _ a: (lon: Double, lat: Double)?,
        _ b: (lon: Double, lat: Double)?
    ) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (l?, r?): return l.lon == r.lon && l.lat == r.lat
        default: return false
        }
    }
}

/// Распарсить словарь `metadata` (name → value) в `MBTilesMetadata`. Never-throw:
/// пропуски/мусор → nil-поля. `bounds` — строго 4 числа через запятую (иначе `nil`);
/// `center` — минимум 2 числа (первые два: lon, lat); зумы — целые. `Double(_:)`
/// локаленезависим (dot-decimal), как и `Int(_:)`.
func parseMBTilesMetadata(_ raw: [String: String]) -> MBTilesMetadata {
    var meta = MBTilesMetadata()

    if let boundsStr = raw["bounds"] {
        let parts = boundsStr.split(separator: ",").map {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        if parts.count == 4, let w = parts[0], let s = parts[1], let e = parts[2], let n = parts[3] {
            meta.bounds = (w: w, s: s, e: e, n: n)
        }
    }

    if let centerStr = raw["center"] {
        let parts = centerStr.split(separator: ",").map {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        if parts.count >= 2, let lon = parts[0], let lat = parts[1] {
            meta.center = (lon: lon, lat: lat)
        }
    }

    if let minStr = raw["minzoom"] {
        meta.minZoom = Int(minStr.trimmingCharacters(in: .whitespaces))
    }
    if let maxStr = raw["maxzoom"] {
        meta.maxZoom = Int(maxStr.trimmingCharacters(in: .whitespaces))
    }

    return meta
}
