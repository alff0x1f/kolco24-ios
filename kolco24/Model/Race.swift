//
//  Race.swift
//  kolco24
//
//  Доменный тип «гонка». Зеркало Room-сущности `RaceEntity`
//  (`data/db/RaceEntity.kt`) — одна строка списка гонок. Сущность одновременно
//  служит моделью приложения (отдельного доменного слоя нет). GRDB-конформанс
//  — в `Data/Records/Race+GRDB.swift` (этап 2).
//
//  Даты и [regStatus] хранятся строками ровно как пришли с сервера
//  (forward-compatible). Первичный ключ [id] — серверный id.
//

/// Одна гонка. [dateEnd] опционален (одно-/многодневные события).
///
/// [mapUrl] — прямой HTTPS-URL оффлайн-подложки `.mbtiles` для этой гонки
/// (`nil` = карты нет). Первая iOS-only колонка сверх Room v5 (миграция `"v2"`,
/// `map_url` в DTO). Дефолт `nil` в `init` — существующие конструкции не трогаем.
struct Race: Equatable {
    let id: Int
    let name: String
    let slug: String
    let date: String
    let dateEnd: String?
    let place: String
    let regStatus: String
    let mapUrl: String?

    init(
        id: Int,
        name: String,
        slug: String,
        date: String,
        dateEnd: String? = nil,
        place: String,
        regStatus: String,
        mapUrl: String? = nil
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.date = date
        self.dateEnd = dateEnd
        self.place = place
        self.regStatus = regStatus
        self.mapUrl = mapUrl
    }
}
