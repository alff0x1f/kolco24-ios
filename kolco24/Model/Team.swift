//
//  Team.swift
//  kolco24
//
//  Доменный тип «команда». Зеркало Room-сущности `TeamEntity`
//  (`data/db/TeamEntity.kt`) — зарегистрированная команда. Сущность одновременно
//  служит моделью приложения. GRDB-конформанс — в `Data/Records/Team+GRDB.swift`
//  (этап 2).
//
//  Принадлежит гонке через [raceId]. [startNumber] опционален (поле бэкенда
//  недавнее, может отсутствовать или быть пустой строкой). [members] хранится
//  JSON-колонкой (аналог `TeamMembersConverter`).
//

/// Участник команды внутри JSON-колонки `teams.members`. Зеркало `TeamMemberItem`.
/// Читается только вместе со своей командой, поэтому живёт сериализованным JSON,
/// а не отдельной таблицей. Ключ JSON — `number_in_team` (задаётся конформансом
/// в `Data/Records/Team+GRDB.swift`, не самим типом).
struct TeamMemberItem: Equatable {
    let name: String
    let numberInTeam: Int
}

/// Одна зарегистрированная команда. Первичный ключ [id] — серверный id;
/// [raceId] связывает строку с гонкой.
struct Team: Equatable {
    let id: Int
    let raceId: Int
    let teamname: String
    let startNumber: String?
    let categoryId: Int?
    let ucount: Int
    let paidPeople: Double
    let startTime: Int64
    let finishTime: Int64
    let members: [TeamMemberItem]

    init(
        id: Int,
        raceId: Int,
        teamname: String,
        startNumber: String? = nil,
        categoryId: Int? = nil,
        ucount: Int,
        paidPeople: Double,
        startTime: Int64,
        finishTime: Int64,
        members: [TeamMemberItem]
    ) {
        self.id = id
        self.raceId = raceId
        self.teamname = teamname
        self.startNumber = startNumber
        self.categoryId = categoryId
        self.ucount = ucount
        self.paidPeople = paidPeople
        self.startTime = startTime
        self.finishTime = finishTime
        self.members = members
    }
}
