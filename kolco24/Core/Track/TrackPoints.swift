//
//  TrackPoints.swift
//  kolco24
//
//  Чистые read-time хелперы GPS-трека. Зеркало читающей части
//  `data/track/TrackModels.kt`: read/export/upload-порядок и reboot-safe сортировка.
//  Фильтр выбросов на чтении (в БД пишется всё сырьё) — `TrackLines.swift`.
//
//  Kotlin абстрагирует эти функции над `TrackPointLike`, потому что и Room-сущность,
//  и другие формы должны сортироваться; в Swift-ядре тип один (`TrackPoint`), поэтому
//  протокол не нужен — функции берут поля напрямую (плановое решение Task 1).
//
//  Upload-часть `TrackModels.kt` (L79–98) уже портирована в `Core/Upload/UploadModels.swift`
//  (этап 6). Склонения — плюралы `Localizable.xcstrings`.
//

import Foundation

/// Порядок отображения/экспорта/загрузки: сначала абсолютное время фикса, монотонное — лишь тай-брейкер.
func trackPointTimeMs(_ point: TrackPoint) -> Int64 {
    point.trustedMs ?? point.wallMs
}

/// Reboot-safe порядок точек трека. `elapsedRealtimeAt` сбрасывается на ребуте устройства, поэтому он
/// не первый: `(timeMs, bootCount ?? -1, elapsedRealtimeAt, id)`.
func sortedTrackPoints(_ points: [TrackPoint]) -> [TrackPoint] {
    points.sorted { lhs, rhs in
        let lt = trackPointTimeMs(lhs), rt = trackPointTimeMs(rhs)
        if lt != rt { return lt < rt }
        let lb = Int64(lhs.bootCount ?? -1), rb = Int64(rhs.bootCount ?? -1)
        if lb != rb { return lb < rb }
        if lhs.elapsedRealtimeAt != rhs.elapsedRealtimeAt { return lhs.elapsedRealtimeAt < rhs.elapsedRealtimeAt }
        return lhs.id < rhs.id
    }
}
