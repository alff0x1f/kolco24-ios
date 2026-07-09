//
//  Checkpoint.swift
//  kolco24
//
//  Доменный тип КП (контрольного пункта) легенды гонки. Зеркало Room-сущности
//  `CheckpointEntity` (`data/db/CheckpointEntity.kt`) — эта сущность одновременно
//  служит моделью приложения (отдельного доменного слоя нет). GRDB-конформанс
//  — в `Data/Records/Checkpoint+GRDB.swift` (этап 2).
//
//  Легенда отдаётся с пошифровкой по КП: `locked`-пункт приходит с конвертом
//  `enc:{iv,ct}` (`encIv`/`encCt`) вместо `cost`/`description` (оба опциональны —
//  открытый текст появляется только после оффлайн-раскрытия). Открытый пункт несёт
//  `cost`/`description` напрямую, без `enc`, `locked = false`.
//

/// Один КП легенды гонки. Первичный ключ [id] — серверный id пункта; [raceId]
/// связывает строку с гонкой (легенду можно заменить целиком).
struct Checkpoint: Equatable {
    let id: Int
    let raceId: Int
    let number: Int
    let cost: Int?
    let type: String
    let description: String?
    let locked: Bool
    let encIv: String?
    let encCt: String?
    let color: String

    init(
        id: Int,
        raceId: Int,
        number: Int,
        cost: Int?,
        type: String,
        description: String?,
        locked: Bool = false,
        encIv: String? = nil,
        encCt: String? = nil,
        color: String = ""
    ) {
        self.id = id
        self.raceId = raceId
        self.number = number
        self.cost = cost
        self.type = type
        self.description = description
        self.locked = locked
        self.encIv = encIv
        self.encCt = encCt
        self.color = color
    }
}
