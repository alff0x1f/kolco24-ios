//
//  PhotoStorage.swift
//  kolco24
//
//  Дисковое хранилище кадров фото-взятий: даунскейл-JPEG на диск (ImageIO) +
//  относительный путь в БД. Платформенный адаптер (прецедент `Nfc/`/`Location/`/
//  `Audio/`) — единственный дом ImageIO-/графических импортов; по конвенции
//  платформенных адаптеров сам он тестируется I/O-тестами во временном каталоге,
//  а чистые швы (`scaledDimensions`/`orphanPhotoDirs` в `Core/Marks/PhotoStorageLogic`,
//  кодек путей `Core/Marks/PhotoPaths`) уже покрыты юнитами.
//
//  Кадры живут под `rootURL/marks/<markId>/<uuid>.jpg`; сосед `<uuid>.thumb.jpg` —
//  best-effort миниатюра тайла. В БД (`marks.photoPath`) хранится только
//  **относительный** путь `marks/<markId>/<uuid>.jpg`; абсолютный резолвится здесь.
//  `rootURL` — каталог `Application Support` (рядом с `kolco24.db`); инжектируется,
//  так что в тестах это временный каталог.
//
//  Порт `data/marks/PhotoStorage.kt`, но ориентация НЕ поворачивается вручную:
//  ImageIO запекает EXIF-ориентацию в пиксели через
//  `kCGImageSourceCreateThumbnailWithTransform = true` (Kotlin `prepareBitmap`
//  крутил битмапу матрицей — здесь этого нет). Константы 1:1 с Kotlin.
//
//  `import ImageIO` живёт только под `Photo/` (grep-инвариант этапа 7).
//

import Foundation
import ImageIO
import CoreGraphics
import os

/// On-disk хранилище кадров фото-взятий + ImageIO-даунскейл. Значимый тип с
/// инжектируемым корнем каталога (`rootURL`) — прод-корень `Application Support`,
/// тестовый — временный каталог.
struct PhotoStorage {

    /// Корень, относительно которого резолвятся относительные пути (`marks/<id>/<uuid>.jpg`).
    /// Прод — `Application Support` (там же `kolco24.db`).
    let rootURL: URL

    // MARK: - Константы (1:1 с Kotlin PhotoStorage)

    /// Длиннейшая сторона сохранённого кадра — держит JPEG достаточно малым для хэш-подписи выгрузки.
    static let maxEdgePx = 1600

    /// Качество JPEG даунскейленного кадра (~80%).
    static let jpegQuality = 0.8

    /// Длиннейшая сторона миниатюры тайла (`<uuid>.thumb.jpg`).
    static let thumbMaxEdge = 512

    /// Качество JPEG миниатюры (~75%).
    static let thumbJpegQuality = 0.75

    private static let log = Logger(subsystem: "kolco24", category: "PhotoStorage")

    // MARK: - Фабрика

    /// Прод-хранилище: корень — каталог `Application Support` (тот же, где `kolco24.db`).
    static func makeShared() throws -> PhotoStorage {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return PhotoStorage(rootURL: appSupport)
    }

    // MARK: - Пути

    /// Корень `marks/` под `rootURL` (родитель всех пофреймовых каталогов взятий).
    var marksRoot: URL { rootURL.appendingPathComponent("marks", isDirectory: true) }

    /// Относительный путь, хранимый в колонке: `marks/<markId>/<fileName>`.
    static func relativePath(markId: String, fileName: String) -> String {
        "marks/\(markId)/\(fileName)"
    }

    /// Абсолютный URL относительного пути кадра (место чтения — рендер/выгрузка).
    func absoluteURL(relPath: String) -> URL {
        rootURL.appendingPathComponent(relPath)
    }

    // MARK: - Запись

    /// Даунскейлить захваченный JPEG [jpegData] так, чтобы длиннейшая сторона была ≤ [maxEdgePx],
    /// перекодировать в [jpegQuality], запечь EXIF-ориентацию в пиксели и записать в свежий
    /// `marks/<markId>/<uuid>.jpg`. Возвращает **относительный** путь при успехе или `nil`, если
    /// декод/запись сорвались (битый кадр молча выбрасывается — вызывающий никогда не добавляет `nil`
    /// в ленту). Рядом best-effort пишется `<uuid>.thumb.jpg` (её сбой не валит кадр).
    ///
    /// Блокирующее I/O — вызывать вне main (фоновой очереди/`Task.detached`).
    func writeDownscaledJpeg(markId: String, jpegData: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil) else {
            Self.log.error("Failed to create image source for mark \(markId, privacy: .public)")
            return nil
        }
        guard let full = Self.downscaled(source, maxPixelSize: Self.maxEdgePx),
              let fullJpeg = Self.encodeJpeg(full, quality: Self.jpegQuality) else {
            Self.log.error("Failed to downscale/encode captured JPEG for mark \(markId, privacy: .public)")
            return nil
        }
        let dir = marksRoot.appendingPathComponent(markId, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            Self.log.error("Failed to create photo dir \(dir.path, privacy: .public): \(String(describing: error))")
            return nil
        }
        let fileName = "\(UUID().uuidString.lowercased()).jpg"
        let fileURL = dir.appendingPathComponent(fileName)
        do {
            try fullJpeg.write(to: fileURL, options: .atomic)
        } catch {
            Self.log.error("Failed to write photo \(fileURL.path, privacy: .public): \(String(describing: error))")
            return nil
        }
        // Кадр надёжно на диске; тумба — best-effort (её сбой не валит кадр, тайл фолбэкнется на кадр).
        Self.writeThumb(source: source, dir: dir, fileName: fileName)
        return Self.relativePath(markId: markId, fileName: fileName)
    }

    /// Записать `<uuid>.thumb.jpg` рядом с кадром: тот же источник, даунскейл до [thumbMaxEdge] при
    /// [thumbJpegQuality]. Никогда не бросает — сбой логируется и молча проглатывается (тайл фолбэкнется
    /// на полный кадр, когда тумбы нет).
    private static func writeThumb(source: CGImageSource, dir: URL, fileName: String) {
        guard let thumb = downscaled(source, maxPixelSize: thumbMaxEdge),
              let thumbJpeg = encodeJpeg(thumb, quality: thumbJpegQuality) else {
            return
        }
        let thumbURL = dir.appendingPathComponent(PhotoPaths.thumbPathOf(fileName))
        do {
            try thumbJpeg.write(to: thumbURL, options: .atomic)
        } catch {
            log.error("Failed to write thumb \(thumbURL.path, privacy: .public): \(String(describing: error))")
        }
    }

    // MARK: - Удаление / sweep

    /// Физически удалить один относительный путь кадра **и его тумбу**; отсутствующие файлы — no-op.
    /// Путь пропускается через `isSafeRelativePhotoPath` (anti-traversal). Безопасно вне main.
    func deleteFrame(relPath: String) {
        guard PhotoPaths.isSafeRelativePhotoPath(relPath) else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: rootURL.appendingPathComponent(relPath))
        try? fm.removeItem(at: rootURL.appendingPathComponent(PhotoPaths.thumbPathOf(relPath)))
    }

    /// Стартовый sweep: удалить каждый каталог `marks/<id>/`, чей `<id>` не является живым id взятия.
    /// Подбирает кадры, осиротевшие смертью процесса mid-capture (каталог есть, строка так и не записана).
    /// [liveMarkIds] — полный набор персистентных id взятий.
    func sweepOrphanDirs(liveMarkIds: Set<String>) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: marksRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return
        }
        let dirNames = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
        for name in orphanPhotoDirs(dirNames: dirNames, liveMarkIds: liveMarkIds) {
            try? fm.removeItem(at: marksRoot.appendingPathComponent(name))
        }
    }

    // MARK: - ImageIO

    /// Даунскейл кадра источника [source] так, чтобы длиннейшая сторона была ≤ [maxPixelSize], с
    /// запечённой EXIF-ориентацией (`…WithTransform`); апскейла нет (маленький кадр остаётся как есть).
    private static func downscaled(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Кодировать [image] в JPEG-`Data` при [quality]; `nil` при любом сбое кодека.
    private static func encodeJpeg(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
