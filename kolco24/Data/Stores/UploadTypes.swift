//
//  UploadTypes.swift
//  kolco24
//
//  Вспомогательные value-типы DAO-запросов дренажа загрузки (этап 2), общие для
//  `MarkStore`/`TrackStore`/`JudgeScanStore`. Зеркала одноимённых Kotlin data-class'ов
//  из `data/db/TrackDao.kt` (`UploadCounts`, `TrackScope`) и `data/db/PhotoFrameRow.kt`.
//  Конформанс `FetchableRecord` живёт здесь (в `Data/`) — это результат агрегатных
//  SELECT'ов без собственной таблицы, поэтому только `init(row:)`, без
//  `PersistableRecord`/`databaseTableName`.
//

import GRDB

/// Прогресс загрузки одного скоупа по каждому таргету — зеркало `UploadCounts`.
/// Room маппит по именам колонок (алиасы `total`/`local`/`cloud`), тут — вручную из `Row`.
struct UploadCounts: Equatable, FetchableRecord {
    let total: Int
    let local: Int
    let cloud: Int

    init(total: Int, local: Int, cloud: Int) {
        self.total = total
        self.local = local
        self.cloud = cloud
    }

    init(row: Row) {
        self.init(
            total: row["total"],
            local: row["local"],
            cloud: row["cloud"]
        )
    }
}

/// Пара `(raceId, teamId)` со строкой, ещё не доставленной хотя бы одному таргету —
/// зеркало `TrackScope`. Результат `SELECT DISTINCT raceId, teamId`.
struct TrackScope: Equatable, Hashable, FetchableRecord {
    let raceId: Int
    let teamId: Int

    init(raceId: Int, teamId: Int) {
        self.raceId = raceId
        self.teamId = teamId
    }

    init(row: Row) {
        self.init(
            raceId: row["raceId"],
            teamId: row["teamId"]
        )
    }
}

/// Сырые frame-флаги одной фото-несущей отметки — зеркало `PhotoFrameRow`. Сворачивается
/// в per-target frame-счётчики на стороне репозитория (этап 3), т.к. `photoPath`-JSON может
/// хранить больше одного кадра.
struct PhotoFrameRow: Equatable, FetchableRecord {
    let photoPath: String?
    let photosUploadedLocal: Bool
    let photosUploadedCloud: Bool

    init(photoPath: String?, photosUploadedLocal: Bool, photosUploadedCloud: Bool) {
        self.photoPath = photoPath
        self.photosUploadedLocal = photosUploadedLocal
        self.photosUploadedCloud = photosUploadedCloud
    }

    init(row: Row) {
        self.init(
            photoPath: row["photoPath"],
            photosUploadedLocal: row["photosUploadedLocal"],
            photosUploadedCloud: row["photosUploadedCloud"]
        )
    }
}
