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
//  загрузке; пустой `Data()` рисует ничего, и там видна Apple-подложка).
//
//  Перезум режет и растягивает тайл через `UIImage`/`UIGraphicsImageRenderer` — они
//  приходят реэкспортом из MapKit; отдельного `import UIKit` нет (grep-инвариант).
//

import Foundation
import MapKit

/// `MKTileOverlay` над оффлайн-подложкой MBTiles. `canReplaceMapContent = false` —
/// рисуется поверх Apple-тайлов: за краем файла и ниже его `minzoom` видна онлайн-карта
/// (без сети — то, что MapKit закешировал). Глубже `maxzoom` файла тайлы вырезаются
/// из тайла на `maxzoom` и растягиваются (перезум) — иначе MapKit оверлей не рисует.
final class MBTilesOverlay: MKTileOverlay {
    /// Источник тайлов: `(z, x, y)` в XYZ-схеме → байты PNG/JPEG или `nil` (нет тайла).
    /// Прод — `MBTilesReader.tileData`; y-flip TMS живёт внутри reader'а.
    private let tileData: @Sendable (Int, Int, Int) -> Data?
    /// `maxzoom` файла — глубже тайлов в нём нет.
    private let fileMaxZ: Int

    /// - Parameters:
    ///   - metadata: метаданные файла — источник `minimumZ` и `maxzoom` (nil-поля → дефолты 0…19).
    ///   - tileData: инжектированный источник тайлов (без GRDB в этом файле).
    init(metadata: MBTilesMetadata?, tileData: @escaping @Sendable (Int, Int, Int) -> Data?) {
        self.tileData = tileData
        // Зумы из метаданных недоверены: зажимаем в 0…22 (иначе `1 << z` в `tmsRow`
        // переполняется), min > max → дефолты 0…19 (`Core/Map` санация, покрыта тестами).
        let zoom = sanitizedZoomRange(minZoom: metadata?.minZoom, maxZoom: metadata?.maxZoom)
        fileMaxZ = zoom.max
        // urlTemplate == nil: тайлы отдаём только через loadTile, не по URL-шаблону.
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = zoom.min
        maximumZ = max(zoom.max, mbtilesOverzoomMaxZoom)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        // Отсутствующий тайл — не ошибка: пустой прозрачный тайл, MapKit не логирует сбой.
        guard let source = overzoomSource(z: path.z, x: path.x, y: path.y, maxZoom: fileMaxZ),
              let data = tileData(source.z, source.x, source.y) else {
            result(Data(), nil)
            return
        }
        if source.levels == 0 {
            result(data, nil)
        } else {
            result(Self.upscale(data, source: source) ?? Data(), nil)
        }
    }

    /// Вырезать клетку `source` из родительского тайла и растянуть до его размера.
    private static func upscale(_ data: Data, source: OverzoomSource) -> Data? {
        guard let parent = UIImage(data: data)?.cgImage else { return nil }
        let size = CGSize(width: parent.width, height: parent.height)
        let cells = CGFloat(1 << source.levels)
        let cell = CGRect(
            x: CGFloat(source.subX) * size.width / cells,
            y: CGFloat(source.subY) * size.height / cells,
            width: size.width / cells,
            height: size.height / cells
        )
        guard let cropped = parent.cropping(to: cell) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            context.cgContext.interpolationQuality = .high
            UIImage(cgImage: cropped).draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
