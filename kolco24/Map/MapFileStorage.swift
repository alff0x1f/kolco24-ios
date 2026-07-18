//
//  MapFileStorage.swift
//  kolco24
//
//  Дисковое хранилище оффлайн-подложки гонки (`.mbtiles`) + скачивание файла.
//  Платформенный адаптер (прецедент `Photo/PhotoStorage`) — но, в отличие от
//  MapKit-файлов под `Map/`, сам он **Foundation-only** (`URLSession` +
//  `FileManager`); `import MapKit` сюда не попадает (grep-инвариант: MapKit
//  живёт только в `MBTilesOverlay`/`TrackMapView`).
//
//  Один файл на гонку: `rootURL/maps/<raceId>.mbtiles` (рядом с `kolco24.db` под
//  `Application Support`, как кадры `PhotoStorage`). Наличие файла = «карта
//  скачана» — отдельного флага в prefs нет. Скачивание: временный файл →
//  атомарный `moveItem`/`replaceItemAt` на место (файл появляется только целым);
//  обрыв/отмена → temp удаляется системой, состояние остаётся `notDownloaded`.
//
//  Сетевой download unit-тестами не покрыт (device/integration, прецедент
//  адаптеров `NfcChipScanner`/`PhotoCameraController`); дисковая часть
//  (`fileURL`/`exists`/`fileSize`/`delete` + установка файла на место)
//  тестируется во временном каталоге.
//

import Foundation
import os

private let mapStorageLog = Logger(subsystem: "kolco24", category: "MapFileStorage")

/// Ошибки скачивания подложки. `.httpError` несёт HTTP-статус (не 2xx).
enum MapDownloadError: Error {
    case httpError(Int)
}

/// On-disk хранилище оффлайн-подложки + `URLSession`-скачивание. Значимый тип с
/// инжектируемым корнем (`rootURL`) — прод-корень `Application Support`, тестовый
/// — временный каталог.
struct MapFileStorage: Sendable {

    /// Корень, под которым лежит подкаталог `maps/`. Прод — `Application Support`
    /// (там же `kolco24.db`).
    let rootURL: URL

    // MARK: - Фабрика

    /// Прод-хранилище: корень — каталог `Application Support` (тот же, где `kolco24.db`).
    static func makeShared() throws -> MapFileStorage {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return MapFileStorage(rootURL: appSupport)
    }

    // MARK: - Пути

    /// Каталог `maps/` под `rootURL` (родитель всех файлов-подложек).
    var mapsRoot: URL { rootURL.appendingPathComponent("maps", isDirectory: true) }

    /// Абсолютный URL файла подложки гонки: `maps/<raceId>.mbtiles`.
    func fileURL(raceId: Int) -> URL {
        mapsRoot.appendingPathComponent("\(raceId).mbtiles")
    }

    /// Скачана ли подложка гонки (файл на диске).
    func exists(raceId: Int) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(raceId: raceId).path)
    }

    /// Размер файла подложки в байтах, или `nil` если файла нет/атрибут недоступен.
    func fileSize(raceId: Int) -> Int64? {
        let path = fileURL(raceId: raceId).path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else {
            return nil
        }
        return size
    }

    /// Удалить файл подложки гонки; отсутствующий файл — no-op.
    func delete(raceId: Int) {
        try? FileManager.default.removeItem(at: fileURL(raceId: raceId))
    }

    // MARK: - Установка на место

    /// Атомарно поставить скачанный временный файл [tempURL] на место подложки
    /// гонки: создать `maps/` при необходимости, затем `replaceItemAt` поверх
    /// существующего файла (докачка = перезапуск с нуля) или `moveItem`, если его
    /// ещё нет. Файл появляется только целым.
    func moveIntoPlace(from tempURL: URL, raceId: Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: mapsRoot, withIntermediateDirectories: true)
        let dest = fileURL(raceId: raceId)
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: dest)
        }
    }

    // MARK: - Скачивание

    /// Скачать подложку [url] для гонки [raceId], репортя прогресс `0…1` через
    /// [onProgress] (`totalBytesExpected` ≤ 0 → индетерминированный `0`). По
    /// завершении: HTTP ≠ 2xx → бросить `MapDownloadError.httpError`, иначе
    /// атомарно поставить файл на место. Отмена (`Task.cancel`) / сетевая ошибка
    /// → бросок; временный файл убирается системой, файл подложки не появляется.
    ///
    /// `URLSessionDownloadTask` через делегат (`didWriteData` → прогресс), а **не**
    /// `URLSession.bytes` с побайтовой итерацией: для 20–60 МБ это O(n) await'ов и
    /// мучительно медленно.
    func download(
        from url: URL,
        raceId: Int,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let delegate = MapDownloadDelegate(onProgress: onProgress)
        // `download(for:delegate:)` завершает `didFinishDownloadingTo` внутри и
        // возвращает временный файл (валиден до возврата из этого вызова — потому
        // ставим на место здесь же). Делегат нужен лишь для прогресса.
        let (tempURL, response) = try await session.download(from: url, delegate: delegate)
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: tempURL)
            throw MapDownloadError.httpError(0)
        }
        guard (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: tempURL)
            mapStorageLog.error("map download HTTP \(http.statusCode) for race \(raceId)")
            throw MapDownloadError.httpError(http.statusCode)
        }
        try moveIntoPlace(from: tempURL, raceId: raceId)
    }
}

/// Делегат `URLSessionDownloadTask` — только прогресс скачивания. `didWriteData`
/// вызывается на очереди делегата сессии; `onProgress` захвачен как `@Sendable`.
private final class MapDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let progress: Double = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        onProgress(progress)
    }

    // Требование протокола: с async `download(for:delegate:)` система обрабатывает
    // завершение сама и возвращает временный файл — здесь ничего не делаем.
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
