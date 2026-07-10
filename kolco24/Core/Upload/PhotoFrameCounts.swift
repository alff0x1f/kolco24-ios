//
//  PhotoFrameCounts.swift
//  kolco24
//
//  Порт `foldPhotoFrameCounts` из `data/MarkRepository.kt` L522–533 — свёртка сырых
//  frame-флагов фото-несущих отметок в пофреймовые `UploadCounts`. Чистый Foundation
//  (Core-инвариант: без GRDB). Вход — лёгкая Core-структура `PhotoFrameInput`, а не
//  GRDB-`PhotoFrameRow` из `Data/Stores/UploadTypes.swift`: `Data/`-адаптер маппит
//  `PhotoFrameRow → PhotoFrameInput` на месте вызова, чтобы Core не тянул `import GRDB`.
//

import Foundation

/// Лёгкий Core-вход свёртки счётчиков кадров: JSON-список путей + два per-target флага.
/// Зеркало полей `PhotoFrameRow`, но без GRDB-конформанса (Core-инвариант).
struct PhotoFrameInput: Equatable {
    /// JSON-массив относительных путей кадров (та же колонка `marks.photoPath`).
    let photoPath: String?
    /// Кадры отметки приняты LAN-целью («Финиш»).
    let local: Bool
    /// Кадры отметки приняты облачной целью («Интернет»).
    let cloud: Bool

    init(photoPath: String?, local: Bool, cloud: Bool) {
        self.photoPath = photoPath
        self.local = local
        self.cloud = cloud
    }
}

/// Свернуть сырые frame-флаги в пофреймовые `UploadCounts`: `total` суммирует число кадров каждой
/// строки (через `PhotoPaths.decode`); `local`/`cloud` прибавляют число кадров строки **только**
/// когда выставлен соответствующий per-target флаг.
///
/// Гранулярность — «тик по марке, знаменатель по кадрам»: mid-drain марка (часть кадров уже принята
/// сервером, но флаг `photosUploadedX` ещё не флипнут — см. `MarkUploadRepository.frameDrainLoop`)
/// добавляет свои кадры в `total`, но **ноль** в числитель, пока не сядут все её кадры и не флипнется
/// флаг. Это ровно то, что БД может честно сообщить (пофреймовое accepted-состояние не персистится,
/// только all-or-nothing per-mark флаг).
func foldPhotoFrameCounts(_ rows: [PhotoFrameInput]) -> UploadCounts {
    var total = 0
    var local = 0
    var cloud = 0
    for row in rows {
        let frameCount = PhotoPaths.decode(row.photoPath).count
        total += frameCount
        if row.local { local += frameCount }
        if row.cloud { cloud += frameCount }
    }
    return UploadCounts(total: total, local: local, cloud: cloud)
}
