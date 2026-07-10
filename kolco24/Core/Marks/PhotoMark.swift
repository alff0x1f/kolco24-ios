//
//  PhotoMark.swift
//  kolco24
//
//  Чистая фабрика строки **standalone фото-взятия**. Kotlin-источник:
//  `MarkRepository.createPhotoMark` (L211–243) — но только конструирование
//  `MarkEntity`; персист (`markDao.upsert`) делает вызывающий (`PhotoModel` через
//  `markStore.upsert`). Тот же паттерн, что `makeKpTakeMark`: UUID и `TimeSample`
//  передаются параметрами — детерминизм и чистота, редьюсер остаётся
//  Android-/GRDB-free.
//
//  [markId] заминчен точкой входа **до** открытия камеры: кадры пишутся в
//  `marks/<markId>/` до существования строки (фикс chicken-and-egg; упавшая до
//  коммита съёмка оставляет сироту, которую подберёт startup-sweep).
//

import Foundation

/// Собрать строку standalone фото-взятия. Гибрид: `method = "photo"`,
/// `complete = true` (зачитывается локально, ждёт проверки судьёй),
/// `present = []` (состав не утверждается — только что команда дошла до КП),
/// `cpUid`/`cpCode` пустые (чип не читался).
///
/// [cp] — разрезолвленный КП; `cost` фолбэчится в `0` для ещё-залоченного КП
/// (`Checkpoint.cost` nil, пока locked) — живой резолвер цены легенды подставит
/// реальную после раскрытия. [expectedCount] — размер ростера, хранится только
/// для серверного лога — `complete` он здесь **не** гонит (ставится явно).
/// [paths] — **относительные** пути кадров; JSON-кодируются в `Mark.photoPath`.
/// Времена — из [sample] (снятого на первом сохранённом кадре), ровно как
/// `makeKpTakeMark` персистит `TimeSample` NFC-взятия.
///
/// Анти-чит координата вешается отдельно через `attachLocation` (тот же
/// column-scoped путь, что у NFC new-take ветки); обвязка точки входа стреляет
/// one-shot `currentLocationProvider`.
func makePhotoMark(
    markId: String,
    cp: Checkpoint,
    raceId: Int,
    teamId: Int,
    paths: [String],
    expectedCount: Int,
    sample: TimeSample
) -> Mark {
    Mark(
        id: markId,
        raceId: raceId,
        teamId: teamId,
        checkpointId: cp.id,
        checkpointNumber: cp.number,
        cost: cp.cost ?? 0,
        method: "photo",
        cpUid: "",
        cpCode: "",
        present: [],
        presentDetails: nil,
        expectedCount: expectedCount,
        complete: true,
        photoPath: PhotoPaths.encode(paths),
        takenAt: sample.wallMs,
        updatedAt: sample.wallMs,
        trustedTakenAt: sample.trustedMs,
        elapsedRealtimeAt: sample.elapsedMs,
        bootCount: sample.bootCount
    )
}
