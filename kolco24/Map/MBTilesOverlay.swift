//
//  MBTilesOverlay.swift
//  kolco24
//
//  Сабкласс `MKTileOverlay`, кормящий MapKit растровыми тайлами оффлайн-подложки.
//  Живёт под `Map/` — единственный дом `import MapKit` (grep-инвариант). Тайлы
//  приходят через инжектированное `@Sendable`-замыкание `tileData(z,x,y)` (прод —
//  `MBTilesReader.tileData`), поэтому GRDB сюда НЕ попадает: `MBTilesReader` под
//  `Data/` остаётся единственным местом `import GRDB`.
//
//  `MKTileOverlay.loadTile` зовётся MapKit конкурентно с фонового queue — reader
//  (один `DatabaseQueue`) это сериализует и выдерживает. Отсутствующий тайл →
//  пустой прозрачный результат (не ошибка — иначе MapKit сыплет лог о неудачной
//  загрузке; пустой `Data()` рисует ничего поверх Apple-тайлов, которых при
//  `canReplaceMapContent = true` всё равно нет).
//

import Foundation
import MapKit

/// `MKTileOverlay` над оффлайн-подложкой MBTiles. `canReplaceMapContent = true` —
/// Apple-тайлы не грузятся вообще; зумовый диапазон — из метаданных (с дефолтами,
/// если в файле их нет).
final class MBTilesOverlay: MKTileOverlay {
    /// Источник тайлов: `(z, x, y)` в XYZ-схеме → байты PNG/JPEG или `nil` (нет тайла).
    /// Прод — `MBTilesReader.tileData`; y-flip TMS живёт внутри reader'а.
    private let tileData: @Sendable (Int, Int, Int) -> Data?

    /// - Parameters:
    ///   - metadata: метаданные файла — источник `minimumZ`/`maximumZ` (nil-поля → дефолты 0…19).
    ///   - tileData: инжектированный источник тайлов (без GRDB в этом файле).
    init(metadata: MBTilesMetadata?, tileData: @escaping @Sendable (Int, Int, Int) -> Data?) {
        self.tileData = tileData
        // urlTemplate == nil: тайлы отдаём только через loadTile, не по URL-шаблону.
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        tileSize = CGSize(width: 256, height: 256)
        // Зумы из метаданных недоверены: зажимаем в 0…22 (иначе `1 << z` в `tmsRow`
        // переполняется), min > max → дефолты 0…19 (`Core/Map` санация, покрыта тестами).
        let zoom = sanitizedZoomRange(minZoom: metadata?.minZoom, maxZoom: metadata?.maxZoom)
        minimumZ = zoom.min
        maximumZ = zoom.max
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        if let data = tileData(path.z, path.x, path.y) {
            result(data, nil)
        } else {
            // Отсутствующий тайл — не ошибка: пустой прозрачный тайл, MapKit не логирует сбой.
            result(Data(), nil)
        }
    }
}
