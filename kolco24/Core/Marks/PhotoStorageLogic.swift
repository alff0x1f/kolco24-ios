//
//  PhotoStorageLogic.swift
//  kolco24
//
//  Чистая (Android-/ImageIO-free) часть дискового хранилища кадров фото-взятий.
//  Порт 1:1 чистых top-level функций `data/marks/PhotoStorage.kt`
//  (`scaledDimensions`, `orphanPhotoDirs`) — JVM-тестируемых на Android и
//  зеркалируемых здесь. Дисковый/ImageIO-адаптер (`Photo/PhotoStorage.swift`,
//  этап 7 Task 3) — единственный потребитель; сам он по конвенции платформенных
//  адаптеров юнитами не кроется, тестируется через эти чистые швы + I/O-тесты
//  во временном каталоге.
//

import Foundation

/// Целевые размеры так, чтобы длиннейшая сторона была ≤ [maxEdge], с сохранением
/// пропорций. Изображение уже в пределах капа (или вырожденный не-положительный
/// размер) возвращается как есть; ни одна сторона никогда не схлопывается в 0
/// (`max(1, …)`). Порт `scaledDimensions`.
func scaledDimensions(width: Int, height: Int, maxEdge: Int) -> (Int, Int) {
    if width <= 0 || height <= 0 { return (width, height) }
    let longest = max(width, height)
    if longest <= maxEdge { return (width, height) }
    let scale = Double(maxEdge) / Double(longest)
    let w = max(1, Int(Double(width) * scale))
    let h = max(1, Int(Double(height) * scale))
    return (w, h)
}

/// Подмножество [dirNames] (каждое — имя подкаталога `marks/` = markId), у
/// которого нет живой строки взятия в [liveMarkIds] — т.е. каталоги-сироты,
/// сметаемые на старте (кадры, осиротевшие из-за смерти процесса mid-capture:
/// каталог есть, строка так и не записана). Порт `orphanPhotoDirs`.
func orphanPhotoDirs(dirNames: [String], liveMarkIds: Set<String>) -> [String] {
    dirNames.filter { !liveMarkIds.contains($0) }
}
