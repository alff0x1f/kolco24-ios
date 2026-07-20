//
//  RacesResponse.swift
//  kolco24
//
//  Зеркало `data/api/dto/RacesResponse.kt` 1:1: проводной payload `GET /app/races/`. Чисто
//  Codable-типы; маппинг в `Model/Race` делает `RaceRepository` (задача 5). Незнакомые ключи
//  игнорируются (дефолт `Codable`).
//

/// Верхнеуровневый payload `GET /app/races/`.
struct RacesResponse: Codable, Equatable {
    let races: [RaceDto]
}

/// Одна опубликованная гонка. Даты и `reg_status` хранятся строками как есть (forward-compat —
/// новые значения `reg_status` не ломают парсинг). `date_end` optional (Django `default=""`/
/// отсутствие ключа старого формата → `nil` через синтезированный `decodeIfPresent`).
struct RaceDto: Codable, Equatable {
    let id: Int
    let name: String
    let slug: String
    let date: String          // "YYYY-MM-DD"
    let dateEnd: String?      // "YYYY-MM-DD" | nil
    let place: String
    let regStatus: String     // "upcoming" | "open" | "sold_out"
    let mapUrl: String?       // прямой HTTPS-URL `.mbtiles` | nil (карты нет)

    enum CodingKeys: String, CodingKey {
        case id, name, slug, date, place
        case dateEnd = "date_end"
        case regStatus = "reg_status"
        case mapUrl = "map_url"
    }
}
