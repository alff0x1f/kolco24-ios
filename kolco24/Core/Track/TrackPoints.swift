//
//  TrackPoints.swift
//  kolco24
//
//  Чистые read-time хелперы GPS-трека. Зеркало читающей части
//  `data/track/TrackModels.kt` (L24–72): фильтр по точности на **чтении** (в БД
//  пишется всё сырьё), read/export/upload-порядок и reboot-safe сортировка.
//
//  Kotlin абстрагирует эти функции над `TrackPointLike`, потому что и Room-сущность,
//  и другие формы должны сортироваться; в Swift-ядре тип один (`TrackPoint`), поэтому
//  протокол не нужен — функции берут поля напрямую (плановое решение Task 1).
//
//  Upload-часть `TrackModels.kt` (L79–98) уже портирована в `Core/Upload/UploadModels.swift`
//  (этап 6); словарь склонений (`pointsWord`/`segmentsWord`/`relativeTimeRu`) — в
//  `Core/Util/PluralRu.swift` (этап 6). Здесь не дублируется.
//

import Foundation

/// Порог точности (метры) по умолчанию для ``filterPoints(_:maxAccuracyMeters:)`` — грубые
/// сетевые фиксы отбрасываются на чтении.
let DEFAULT_MAX_ACCURACY_METERS: Float = 50

/// Отбросить грубые фиксы (``TrackPoint/accuracy`` хуже [maxAccuracyMeters]) для отображения/экспорта.
/// **Только чтение** — каждый фикс всё равно хранится в БД сырым.
func filterPoints(_ points: [TrackPoint], maxAccuracyMeters: Float = DEFAULT_MAX_ACCURACY_METERS) -> [TrackPoint] {
    points.filter { $0.accuracy <= maxAccuracyMeters }
}

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
