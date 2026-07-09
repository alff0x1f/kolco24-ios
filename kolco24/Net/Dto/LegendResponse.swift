//
//  LegendResponse.swift
//  kolco24
//
//  Зеркало `data/api/dto/LegendResponse.kt` 1:1: проводной payload `GET /app/race/<id>/legend/`.
//  Два массива — `checkpoints` (легенда КП) и `tags` (физические NFC-метки) — плюс агрегаты
//  `total_cost`/`scoring_count`. Маппинг делает `LegendRepository` (задача 7). Forward-compat:
//  `total_cost`/`scoring_count` дефолт `0`, `tags` дефолт `[]` — через ручной `init(from:)`
//  (`decodeIfPresent ?? default`; синтезированный `Codable` бросил бы `keyNotFound`, дефолты
//  свойств не подхватывает). Locked-КП приходит без `cost`/`description`, только с `enc` —
//  `enc != nil` сентинел locked. `EncDto{iv, ct}` — base64-строки.
//

/// Верхнеуровневый payload `GET /app/race/<id>/legend/`.
///
/// `totalCost` — сумма `cost` **всех** КП (открытых и закрытых): корректный знаменатель прогресс-бара
/// легенды, даже когда закрытые КП скрывают свою `cost`. `scoringCount` — число КП c `cost > 0`
/// (открытых и закрытых): знаменатель счётчика взятых КП (технические КП c `cost = 0` не в счёт).
/// Оба дефолтятся `0` для forward-compat и персистятся пер-гонка в `legend_meta`.
struct LegendResponse: Codable, Equatable {
    let race: Int
    let totalCost: Int          // дефолт 0
    let scoringCount: Int       // дефолт 0
    let checkpoints: [CheckpointDto]
    let tags: [TagDto]          // дефолт []

    enum CodingKeys: String, CodingKey {
        case race, checkpoints, tags
        case totalCost = "total_cost"
        case scoringCount = "scoring_count"
    }

    init(race: Int, totalCost: Int = 0, scoringCount: Int = 0, checkpoints: [CheckpointDto], tags: [TagDto] = []) {
        self.race = race
        self.totalCost = totalCost
        self.scoringCount = scoringCount
        self.checkpoints = checkpoints
        self.tags = tags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        race = try c.decode(Int.self, forKey: .race)
        totalCost = try c.decodeIfPresent(Int.self, forKey: .totalCost) ?? 0
        scoringCount = try c.decodeIfPresent(Int.self, forKey: .scoringCount) ?? 0
        checkpoints = try c.decode([CheckpointDto].self, forKey: .checkpoints)
        tags = try c.decodeIfPresent([TagDto].self, forKey: .tags) ?? []
    }
}

/// Одна КП легенды. Поля плоские (без snake_case), потому маппинг ключей не нужен.
/// `type` ∈ `start|finish|test|kp` — plain-строка (forward-compat: неизвестные типы не ломают
/// парсинг). **Закрытая** КП (`is_legend_locked` на сервере) приходит без `cost`/`description` —
/// открытый текст не покидает сервер — и несёт `enc` конверт: `enc != nil` — сентинел locked,
/// потому `cost`/`description` optional. `color` — **публичный** семантический токен
/// (`""`/`red`/`blue`/`green`/`yellow`/`orange`/`purple`), есть в обеих ветках (не прячется за
/// `enc`); optional, репозиторий приводит `nil` к `""` (`?? ""`).
struct CheckpointDto: Codable, Equatable {
    let id: Int
    let number: Int
    let cost: Int?              // nil у locked-КП
    let type: String           // start|finish|test|kp
    let description: String?    // nil у locked-КП
    let enc: EncDto?           // != nil — сентинел locked
    let color: String?         // nil → "" в репозитории
}

/// Конверт AES-256-GCM: `iv` (12 байт, base64) + `ct` (`ciphertext || tag(16)`, base64).
struct EncDto: Codable, Equatable {
    let iv: String
    let ct: String
}

/// Одна физическая NFC-метка. `bid` (`sha256(code)[:16]`) — офлайн-идентификация скана: `bid →
/// checkpoint_id` (id КП, переименован из `point` на сервере; в примере API.md устаревший `point`).
/// `iv`/`ct` — конверт `bundle_blob` для офлайн-разблокировки закрытых КП; `nil` у меток открытых
/// КП (только идентификация). `iv`/`ct` — base64-строки.
struct TagDto: Codable, Equatable {
    let bid: String
    let checkpointId: Int
    let checkMethod: String
    let iv: String?
    let ct: String?

    enum CodingKeys: String, CodingKey {
        case bid, iv, ct
        case checkpointId = "checkpoint_id"
        case checkMethod = "check_method"
    }
}
