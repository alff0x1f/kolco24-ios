//
//  Tag.swift
//  kolco24
//
//  Доменный тип «NFC-тег легенды». Зеркало Room-сущности `TagEntity`
//  (`data/db/TagEntity.kt`) — маппит [bid] тега (производный
//  `sha256(code)[:16]`) на КП ([checkpointId]). Сущность одновременно служит
//  моделью приложения. GRDB-конформанс — в `Data/Records/Tag+GRDB.swift`
//  (этап 2).
//
//  Тег, открывающий **locked**-КП, несёт конверт раскрытия ([iv]/[ct], Base64);
//  тег открытого КП — оба nil. [checkMethod] — серверная строка `check_method`.
//  Композитный первичный ключ `(raceId, bid)` изолирует теги по гонкам.
//

/// Один NFC-тег легенды. Матчится на скане по [bid] внутри [raceId].
struct Tag: Equatable {
    let raceId: Int
    let bid: String
    let checkpointId: Int
    let checkMethod: String
    let iv: String?
    let ct: String?

    init(
        raceId: Int,
        bid: String,
        checkpointId: Int,
        checkMethod: String,
        iv: String? = nil,
        ct: String? = nil
    ) {
        self.raceId = raceId
        self.bid = bid
        self.checkpointId = checkpointId
        self.checkMethod = checkMethod
        self.iv = iv
        self.ct = ct
    }
}
