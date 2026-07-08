//
//  SelectedTeam.swift
//  kolco24
//
//  Доменный тип «выбранная команда». Зеркало Room-сущности `SelectedTeamEntity`
//  (`data/db/SelectedTeamEntity.kt`) — таблица из одной строки (фикс. PK [id] = 1),
//  чей observation переключает вкладку «Команда» между пустым состоянием и
//  ростером выбранной команды. GRDB-конформанс — в
//  `Data/Records/SelectedTeam+GRDB.swift` (этап 2).
//

/// Текущая выбранная команда. [id] всегда 1 (одно-строчная таблица).
struct SelectedTeam: Equatable {
    let id: Int
    let raceId: Int
    let teamId: Int

    init(id: Int = 1, raceId: Int, teamId: Int) {
        self.id = id
        self.raceId = raceId
        self.teamId = teamId
    }
}
