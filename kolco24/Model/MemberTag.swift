//
//  MemberTag.swift
//  kolco24
//
//  Доменный тип «слот member-тега». Зеркало Room-сущности `MemberTagEntity`
//  (`data/db/MemberTagEntity.kt`) — один слот из пула `member_tags` гонки:
//  участник [number] в паре с нормализованным [nfcUid] его браслета. Сущность
//  одновременно служит моделью приложения. GRDB-конформанс — в
//  `Data/Records/MemberTag+GRDB.swift` (этап 2).
//
//  Пул моделируется **пер-гонка** ([raceId]); `member_tags` API не несёт
//  внутреннего id — слот идентифицируется по [nfcUid], поэтому композитный
//  первичный ключ `(raceId, nfcUid)`.
//

/// Один слот member-тега.
struct MemberTag: Equatable {
    let raceId: Int
    let nfcUid: String
    let number: Int
}
