//
//  Race.swift
//  kolco24
//
//  Доменный тип «гонка». Зеркало Room-сущности `RaceEntity`
//  (`data/db/RaceEntity.kt`) — одна строка списка гонок. Сущность одновременно
//  служит моделью приложения (отдельного доменного слоя нет). GRDB-конформанс
//  добавит этап 2.
//
//  Даты и [regStatus] хранятся строками ровно как пришли с сервера
//  (forward-compatible). Первичный ключ [id] — серверный id.
//

/// Одна гонка. [dateEnd] опционален (одно-/многодневные события).
struct Race: Equatable {
    let id: Int
    let name: String
    let slug: String
    let date: String
    let dateEnd: String?
    let place: String
    let regStatus: String

    init(
        id: Int,
        name: String,
        slug: String,
        date: String,
        dateEnd: String? = nil,
        place: String,
        regStatus: String
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.date = date
        self.dateEnd = dateEnd
        self.place = place
        self.regStatus = regStatus
    }
}
