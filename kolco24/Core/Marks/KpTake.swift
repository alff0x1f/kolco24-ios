//
//  KpTake.swift
//  kolco24
//
//  Чистая фабрика строки взятия КП. Kotlin-источник: `MarkRepository.startKpTake`
//  (127–167) — но только конструирование `MarkEntity`; персист (`markDao.upsert`)
//  делает вызывающий (`ScanModel` через `markStore.upsert`). Вынос в чистую
//  функцию — чтобы редьюсер скана оставался Android-/GRDB-free и тестировался без
//  БД (UUID передаётся параметром — детерминизм и чистота).
//
//  Строка рождается в момент скана чипа КП (переживает смерть процесса), затем
//  `present` накапливает участников через `MarkStore.addMember`. `complete`
//  (= идёт в зачёт) ставится, как только буфер уже покрыл весь ростер.
//

import Foundation

/// Собрать строку взятия КП из первого скана чипа пункта и текущего буфера
/// участников. Порт `startKpTake`: и `present` (истина зачёта), и `presentDetails`
/// (снимки для загрузки) выводятся одним `distinctBy { numberInTeam }`-проходом
/// над буфером; `complete = expectedCount > 0 && present.count >= expectedCount`.
/// Метод `"nfc"`; `takenAt`/`updatedAt` — сырой wall из семпла; `trustedTakenAt`/
/// `elapsedRealtimeAt`/`bootCount` — из того же [sample] (monotonic-anchored
/// forensics). [id] генерирует вызывающий (UUID) — так функция остаётся чистой.
func makeKpTakeMark(
    id: String,
    raceId: Int,
    teamId: Int,
    checkpointId: Int,
    number: Int,
    cost: Int,
    cpUid: String,
    cpCode: String,
    buffered: [MarkMemberSnapshot],
    expectedCount: Int,
    sample: TimeSample
) -> Mark {
    // Один distinct-проход по слоту питает и present (истина зачёта), и
    // presentDetails (снимки загрузки) — задвоенный слот схлопывается, а не
    // раздувает present/complete.
    var seenSlots = Set<Int>()
    var distinct: [MarkMemberSnapshot] = []
    for snapshot in buffered where seenSlots.insert(snapshot.numberInTeam).inserted {
        distinct.append(snapshot)
    }
    let present = distinct.map { $0.numberInTeam }
    let complete = expectedCount > 0 && present.count >= expectedCount

    return Mark(
        id: id,
        raceId: raceId,
        teamId: teamId,
        checkpointId: checkpointId,
        checkpointNumber: number,
        cost: cost,
        method: "nfc",
        cpUid: cpUid,
        cpCode: cpCode,
        present: present,
        presentDetails: distinct,
        expectedCount: expectedCount,
        complete: complete,
        takenAt: sample.wallMs,
        updatedAt: sample.wallMs,
        trustedTakenAt: sample.trustedMs,
        elapsedRealtimeAt: sample.elapsedMs,
        bootCount: sample.bootCount
    )
}
