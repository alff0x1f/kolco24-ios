//
//  LegendMeta.swift
//  kolco24
//
//  Доменный тип «агрегаты легенды». Зеркало Room-сущности `LegendMetaEntity`
//  (`data/db/LegendMetaEntity.kt`) — гонко-уровневые агрегаты легенды без
//  пер-КП дома: [totalCost] (сумма `cost` **всех** КП, открытых + locked) и
//  [scoringCount] (число КП с `cost > 0`) из полей `total_cost`/`scoring_count`
//  ответа легенды. GRDB-конформанс — в `Data/Records/LegendMeta+GRDB.swift`
//  (этап 2).
//
//  Существуют потому, что **locked**-КП скрывает свой `cost` (открытый текст не
//  покидает сервер), и клиент не может пересчитать агрегаты из строк КП. Одна
//  строка на гонку, ключ [raceId].
//

/// Агрегаты легенды одной гонки.
struct LegendMeta: Equatable {
    let raceId: Int
    let totalCost: Int
    let scoringCount: Int
}
