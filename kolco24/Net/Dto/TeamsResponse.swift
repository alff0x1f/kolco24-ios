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
///
/// Ловушка порт-верности: `category2: Int?` в Kotlin — nullable БЕЗ дефолта, а в
/// kotlinx.serialization это значит «ключ обязателен, но `null` допустим» (отсутствие ключа →
/// `MissingFieldException`). Синтезированный Swift-`Codable` для Optional зовёт `decodeIfPresent`
/// (отсутствие ключа → `nil`), что молча приняло бы битый payload. Потому ручной `init(from:)`:
/// `decode(Int?.self)` требует наличие ключа `category2` (явный `null` по-прежнему валиден), а
/// остальные поля декодируются 1:1 (обязательные — `decode`, `start_number` c дефолтом-`null` —
/// `decodeIfPresent`).
struct TeamDto: Codable, Equatable {
    let id: Int
    let teamname: String
    let startNumber: String?   // nil у старого формата / Django default=""
    let category2: Int?        // id категории; null → команда не в выдаче; ключ обязателен
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

    init(id: Int, teamname: String, startNumber: String? = nil, category2: Int?, ucount: Int,
         paidPeople: Double, startTime: Int64, finishTime: Int64, members: [MemberDto]) {
        self.id = id
        self.teamname = teamname
        self.startNumber = startNumber
        self.category2 = category2
        self.ucount = ucount
        self.paidPeople = paidPeople
        self.startTime = startTime
        self.finishTime = finishTime
        self.members = members
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        teamname = try c.decode(String.self, forKey: .teamname)
        startNumber = try c.decodeIfPresent(String.self, forKey: .startNumber)
        category2 = try c.decode(Int?.self, forKey: .category2)  // ключ обязателен, null допустим
        ucount = try c.decode(Int.self, forKey: .ucount)
        paidPeople = try c.decode(Double.self, forKey: .paidPeople)
        startTime = try c.decode(Int64.self, forKey: .startTime)
        finishTime = try c.decode(Int64.self, forKey: .finishTime)
        members = try c.decode([MemberDto].self, forKey: .members)
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
