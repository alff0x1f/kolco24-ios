//
//  PhotoStorageTests.swift
//  kolco24Tests
//
//  I/O-тесты дискового/ImageIO-адаптера `Photo/PhotoStorage.swift` во временном
//  каталоге (файловое I/O и ImageIO работают в hosted-тестах симулятора). Зеркала
//  для чистых `scaledDimensions`/`orphanPhotoDirs` — в `PhotoStorageLogicTests`;
//  здесь проверяется реальная запись/даунскейл/ориентация/удаление/sweep.
//
//  `import ImageIO` — только для генерации тестового JPEG и чтения пиксельных
//  размеров записанного файла; путь `kolco24Tests/Photo/` — тестовый дом
//  фото-адаптера (grep-инвариант про ImageIO касается прод-модуля под `Photo/`).
//

import Foundation
import ImageIO
import CoreGraphics
import Testing
@testable import kolco24

struct PhotoStorageTests {

    // MARK: - Инфраструктура

    /// Свежий временный каталог-корень на каждый тест; удаляется в конце.
    private func withTempStorage(_ body: (PhotoStorage, URL) throws -> Void) rethrows {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("kolco24-phototest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try body(PhotoStorage(rootURL: root), root)
    }

    /// Сгенерировать валидный JPEG заданных пиксельных размеров, опционально с EXIF-ориентацией
    /// (`kCGImagePropertyOrientation`, значение 6 = поворот на 90°).
    private func makeJpegData(width: Int, height: Int, orientation: Int? = nil) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!

        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let orientation {
            props[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    /// Пиксельные размеры JPEG-файла (игнорируя EXIF-ориентацию — читаем сырые pixelWidth/Height).
    private func pixelSize(of url: URL) -> (Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (w, h)
    }

    // MARK: - writeDownscaledJpeg

    @Test func writeCreatesFrameAndThumbWithRelativePath() throws {
        try withTempStorage { storage, root in
            let jpeg = makeJpegData(width: 4000, height: 3000)
            let rel = try #require(storage.writeDownscaledJpeg(markId: "m1", jpegData: jpeg))

            // Относительный путь ровно marks/<markId>/<uuid>.jpg и безопасен.
            #expect(rel.hasPrefix("marks/m1/"))
            #expect(rel.hasSuffix(".jpg"))
            #expect(PhotoPaths.isSafeRelativePhotoPath(rel))

            let frameURL = root.appendingPathComponent(rel)
            let thumbURL = root.appendingPathComponent(PhotoPaths.thumbPathOf(rel))
            #expect(FileManager.default.fileExists(atPath: frameURL.path))
            #expect(FileManager.default.fileExists(atPath: thumbURL.path))
        }
    }

    @Test func writeDownscalesLongestEdgeToCap() throws {
        try withTempStorage { storage, root in
            let jpeg = makeJpegData(width: 4000, height: 3000)
            let rel = try #require(storage.writeDownscaledJpeg(markId: "m1", jpegData: jpeg))

            let (fw, fh) = try #require(pixelSize(of: root.appendingPathComponent(rel)))
            #expect(max(fw, fh) <= PhotoStorage.maxEdgePx)
            // Пропорции сохранены: 4000x3000 → 1600x1200.
            #expect(fw == 1600)
            #expect(fh == 1200)

            let (tw, th) = try #require(pixelSize(of: root.appendingPathComponent(PhotoPaths.thumbPathOf(rel))))
            #expect(max(tw, th) <= PhotoStorage.thumbMaxEdge)
        }
    }

    @Test func writeLeavesSmallImageUnchangedInSize() throws {
        try withTempStorage { storage, root in
            let jpeg = makeJpegData(width: 800, height: 600)
            let rel = try #require(storage.writeDownscaledJpeg(markId: "m1", jpegData: jpeg))
            let (fw, fh) = try #require(pixelSize(of: root.appendingPathComponent(rel)))
            #expect(fw == 800)
            #expect(fh == 600)
        }
    }

    @Test func writeBakesExifOrientationIntoPixels() throws {
        try withTempStorage { storage, root in
            // Landscape 800x400 пиксели, но EXIF orientation 6 (поворот 90°) → визуально portrait.
            let jpeg = makeJpegData(width: 800, height: 400, orientation: 6)
            let rel = try #require(storage.writeDownscaledJpeg(markId: "m1", jpegData: jpeg))

            let (fw, fh) = try #require(pixelSize(of: root.appendingPathComponent(rel)))
            // Ориентация запечена в пиксели (transform), тег ориентации сброшен: portrait 400x800.
            #expect(fw == 400)
            #expect(fh == 800)
        }
    }

    @Test func writeReturnsNilForGarbageBytesAndLeavesNoFiles() throws {
        try withTempStorage { storage, _ in
            let garbage = Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xEE])
            #expect(storage.writeDownscaledJpeg(markId: "m1", jpegData: garbage) == nil)
            // Каталог кадра не создан.
            let dir = storage.marksRoot.appendingPathComponent("m1")
            #expect(!FileManager.default.fileExists(atPath: dir.path))
        }
    }

    // MARK: - deleteFrame

    @Test func deleteRemovesFrameAndThumb() throws {
        try withTempStorage { storage, root in
            let jpeg = makeJpegData(width: 1000, height: 800)
            let rel = try #require(storage.writeDownscaledJpeg(markId: "m1", jpegData: jpeg))
            let frameURL = root.appendingPathComponent(rel)
            let thumbURL = root.appendingPathComponent(PhotoPaths.thumbPathOf(rel))
            #expect(FileManager.default.fileExists(atPath: frameURL.path))

            storage.deleteFrame(relPath: rel)
            #expect(!FileManager.default.fileExists(atPath: frameURL.path))
            #expect(!FileManager.default.fileExists(atPath: thumbURL.path))
        }
    }

    @Test func deleteIgnoresUnsafePath() throws {
        try withTempStorage { storage, root in
            // Записываем настоящий кадр, затем зовём delete с traversal-путём — реальный файл цел.
            let jpeg = makeJpegData(width: 200, height: 200)
            let rel = try #require(storage.writeDownscaledJpeg(markId: "m1", jpegData: jpeg))
            storage.deleteFrame(relPath: "../m1/../../etc/passwd.jpg")
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path))
        }
    }

    // MARK: - sweepOrphanDirs

    @Test func sweepRemovesOnlyOrphanDirs() throws {
        try withTempStorage { storage, _ in
            let jpeg = makeJpegData(width: 200, height: 200)
            _ = storage.writeDownscaledJpeg(markId: "live", jpegData: jpeg)
            _ = storage.writeDownscaledJpeg(markId: "orphan", jpegData: jpeg)

            let liveDir = storage.marksRoot.appendingPathComponent("live")
            let orphanDir = storage.marksRoot.appendingPathComponent("orphan")
            #expect(FileManager.default.fileExists(atPath: liveDir.path))
            #expect(FileManager.default.fileExists(atPath: orphanDir.path))

            storage.sweepOrphanDirs(liveMarkIds: ["live"])

            #expect(FileManager.default.fileExists(atPath: liveDir.path))
            #expect(!FileManager.default.fileExists(atPath: orphanDir.path))
        }
    }

    @Test func sweepIsNoOpWhenMarksRootMissing() throws {
        try withTempStorage { storage, _ in
            // marks/ ещё не создан — sweep не должен бросать.
            storage.sweepOrphanDirs(liveMarkIds: ["anything"])
            #expect(!FileManager.default.fileExists(atPath: storage.marksRoot.path))
        }
    }
}
