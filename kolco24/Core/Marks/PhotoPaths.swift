//
//  PhotoPaths.swift
//  kolco24
//
//  Чистый (Android-free) кодек и валидатор JSON-списка относительных путей фото,
//  хранящихся в существующей TEXT-колонке `marks.photoPath`. Порт 1:1
//  `data/marks/PhotoPaths.kt` (этап 7). Фото-взятие несёт N кадров; хранение их
//  JSON-массивом в уже-nullable колонке оставляет схему migration-free (тип
//  колонки остаётся TEXT), а число кадров тривиально выводится из разобранного
//  списка — отдельная колонка `photoCount` не нужна.
//
//  Пути хранятся **относительно** каталога приложения (`marks/<markId>/<uuid>.jpg`);
//  абсолютный файл резолвится на месте чтения/записи, никогда здесь (у чистого
//  маппера нет корня каталога). `import GRDB`/`import Data` запрещены — Core-инвариант,
//  поэтому используется собственный `JSONEncoder`/`JSONDecoder`, а не Data-`JSONColumnCodec`.
//

import Foundation
import os

/// Чистый Core-кодек путей фото. Никакого Android/GRDB; собственные encoder/decoder,
/// чтобы не тянуть в Core Data-слойный `JSONColumnCodec`.
enum PhotoPaths {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// JSON-кодирование списка относительных путей фото. Зеркало Room JSON-конвертеров; порядок сохраняется.
    /// При сбое кодирования → `"[]"` (никогда не бросает).
    static func encode(_ paths: [String]) -> String {
        guard let data = try? encoder.encode(paths),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    /// Декодирование `photoPath`-колонки в список **валидированных** относительных путей. Никогда не
    /// бросает — `nil`, blank, битый JSON или не-массив декодируются в `[]`. Каждый элемент обязан
    /// совпадать с ожидаемой формой `marks/<markId>/<uuid>.jpg`; **абсолютные пути и любой с `..`
    /// отбрасываются**, чтобы позднейший `rootURL + relPath` не мог выйти за корень (path-traversal guard).
    static func decode(_ raw: String?) -> [String] {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = raw.data(using: .utf8) else {
            return []
        }
        let decoded: [String]
        do {
            decoded = try decoder.decode([String].self, from: data)
        } catch {
            Logger(subsystem: "kolco24", category: "PhotoPaths")
                .error("Failed to decode photo paths JSON: \(String(describing: error))")
            return []
        }
        return decoded.filter(isSafeRelativePhotoPath)
    }

    /// `marks/<markId>/<uuid>.jpg`: 3-сегментный относительный путь под `marks/`, без абсолютного
    /// префикса, без сегмента-`..`, оканчивающийся на `.jpg`. Всё прочее — испорченная/враждебная
    /// запись и отбрасывается.
    static func isSafeRelativePhotoPath(_ path: String) -> Bool {
        if isBlank(path) { return false }
        if path.hasPrefix("/") { return false }
        if !path.hasSuffix(".jpg") { return false }
        let segments = path.components(separatedBy: "/")
        if segments.count != 3 { return false }
        if segments.first != "marks" { return false }
        if segments.contains(where: { isBlank($0) || $0 == "." || $0 == ".." }) { return false }
        return true
    }

    /// Стем `<uuid>` имени файла относительного пути фото (`marks/<markId>/<uuid>.jpg` → `<uuid>`) —
    /// стабильная уникальная идентичность кадра, используемая как ключ идемпотентности на эндпоинте
    /// выгрузки кадра.
    static func frameIdOf(_ relPath: String) -> String {
        let fileName = relPath.components(separatedBy: "/").last ?? relPath
        if fileName.hasSuffix(".jpg") {
            return String(fileName.dropLast(".jpg".count))
        }
        return fileName
    }

    /// Путь миниатюры кадра (`marks/<markId>/<uuid>.jpg` → `marks/<markId>/<uuid>.thumb.jpg`).
    /// Тумбы — **конвенция имени, никогда не запись в `photoPath`** (колонка держит только реальные
    /// кадры — дренаж выгрузки шлёт каждую запись на сервер), поэтому тумба выводится на месте
    /// рендера/удаления. Также принимает голое `<uuid>.jpg` (при записи тумбы рядом с её кадром).
    static func thumbPathOf(_ framePath: String) -> String {
        if framePath.hasSuffix(".jpg") {
            return String(framePath.dropLast(".jpg".count)) + ".thumb.jpg"
        }
        return framePath + ".thumb.jpg"
    }

    /// Зеркало Kotlin `String.isBlank()`: пусто или только whitespace.
    private static func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
