//
//  Category.swift
//  kolco24
//
//  Доменный тип «категория гонки» (дистанция/группа). Зеркало Room-сущности
//  `CategoryEntity` (`data/db/CategoryEntity.kt`) — зеркало `CategoryDto`.
//  GRDB-конформанс — в `Data/Records/Category+GRDB.swift` (этап 2).
//
//  Принадлежит гонке через [raceId]. Серверное поле `order` — зарезервированное
//  SQL-слово, поэтому колонка называется [sortOrder].
//
//  [controlTime] — серверное поле `control_time` сверх Room v5 (iOS-only колонка,
//  миграция `"v3"`): контрольное время в минутах, `0` = не задано.
//

/// Одна категория гонки. Первичный ключ [id] — серверный id.
struct Category: Equatable {
    let id: Int
    let raceId: Int
    let code: String
    let shortName: String
    let name: String
    let sortOrder: Int
    let controlTime: Int

    init(
        id: Int,
        raceId: Int,
        code: String,
        shortName: String,
        name: String,
        sortOrder: Int,
        controlTime: Int = 0
    ) {
        self.id = id
        self.raceId = raceId
        self.code = code
        self.shortName = shortName
        self.name = name
        self.sortOrder = sortOrder
        self.controlTime = controlTime
    }
}
