//
//  TeamsResponse.swift
//  kolco24
//
//  Зеркало `data/api/dto/TeamsResponse.kt` 1:1: проводной payload `GET /app/race/<id>/teams/`.
//  Маппинг DTO → `Model/Category` (`order`→`sortOrder`) и `Model/Team` (+`TeamMemberItem`) делает
//  `TeamRepository` (задача 6). Ловушки: `paid_people` — Double; `start_time`/`finish_time` —
//  миллисекунды (`Int64`, `0` = не стартовали/не финишировали); `start_number` — optional.
//

/// Верхнеуровневый payload `GET /app/race/<id>/teams/`.
struct TeamsResponse: Codable, Equatable {
    let race: Int
    let categories: [CategoryDto]
    let teams: [TeamDto]
}

/// Категория гонки (дистанция/группа). `order` — зарезервированное SQL-слово, потому маппинг
/// на `sortOrder` делает репозиторий; в DTO поле остаётся `order`.
struct CategoryDto: Codable, Equatable {
    let id: Int
    let code: String
    let shortName: String
    let name: String
    let order: Int

    enum CodingKeys: String, CodingKey {
        case id, code, name, order
        case shortName = "short_name"
    }
}

/// Зарегистрированная команда. `start_number` nullable c дефолтом: бэкенд добавил его недавно и
/// он не задокументирован в API.md, потому optional (отсутствие ключа старого формата и Django
/// `default=""` → `nil`). `paid_people` — Double (например `4.0`). `start_time`/`finish_time` —
/// unix-**миллисекунды** (`0` = нет).
struct TeamDto: Codable, Equatable {
    let id: Int
    let teamname: String
    let startNumber: String?   // nil у старого формата / Django default=""
    let category2: Int?        // id категории; null → команда не в выдаче
    let ucount: Int
    let paidPeople: Double
    let startTime: Int64       // ms, 0 = не стартовали
    let finishTime: Int64      // ms, 0 = не финишировали
    let members: [MemberDto]

    enum CodingKeys: String, CodingKey {
        case id, teamname, category2, ucount, members
        case startNumber = "start_number"
        case paidPeople = "paid_people"
        case startTime = "start_time"
        case finishTime = "finish_time"
    }
}

/// Один участник команды. У участников нет id — слот идентифицируется по `number_in_team`.
struct MemberDto: Codable, Equatable {
    let name: String
    let numberInTeam: Int

    enum CodingKeys: String, CodingKey {
        case name
        case numberInTeam = "number_in_team"
    }
}
