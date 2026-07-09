//
//  TeamRepository.swift
//  kolco24
//
//  Зеркало `data/TeamRepository.kt` 1:1 — единый источник правды по командам + категориям одной
//  гонки и текущей выбранной команде. БД держит данные, сеть их только обновляет. UI читает
//  `teamsForRace`/`categoriesForRace`/`selectedTeam`; `refreshTeams` делает условный GET и на `200`
//  целиком заменяет строки этой гонки.
//
//  Refresh-поток скопирован с `RaceRepository` (ЭТАЛОН): три РАЗДЕЛЬНЫЕ транзакции в порядке
//  «данные → потом ETag», `deleteEtag` другого origin — ДО замены. ОТЛИЧИЕ от Race — pin-guard:
//  гонки глобальны, а команды/легенда/member-теги привязаны к raceId, который может быть пришпилен
//  к LAN. `isRacePinned`-seam сейчас всегда `false` (этап 9 подставит lease). Guard проверяется ДО
//  сетевого вызова И повторно после `200` (защита от смены источника в полёте — свежие строки
//  другого источника не затираются ответом того, что только что потерял актуальность).
//
//  `import GRDB` — из-за реэкспорта `AsyncValueObservation`; допустимо, файл под `Data/`.
//  Маппинг `CategoryDto` → `Model/Category` (`order`→`sortOrder`) и `TeamDto` → `Model/Team`
//  (+`TeamMemberItem`, ms-время) — здесь.
//

import GRDB

/// Имя ресурса команд одной гонки в `sync_meta` (партиция по origin).
private func teamsResource(_ raceId: Int) -> String { "race/\(raceId)/teams" }

/// Единый источник правды по командам + категориям одной гонки и выбранной команде.
///
/// - Parameters:
///   - origin: base URL cloud-клиента — ключ-партиция ETag в `sync_meta`.
///   - localOrigin: base URL LAN-клиента — ключ-партиция ETag для LAN-фетчей.
///   - isRacePinned: `true`, когда `raceId` сейчас пришпилен к LAN. Cloud-refresh пришпиленной
///     гонки не персистит (устаревшее облачное зеркало не должно затирать свежие локальные строки),
///     и симметрично Local-refresh НЕ-пришпиленной гонки тоже не персистит. Сейчас всегда `false`;
///     этап 9 подставит lease.
struct TeamRepository {
    let apiClient: ApiClient
    let teamStore: TeamStore
    let selectedTeamStore: SelectedTeamStore
    let syncMetaStore: SyncMetaStore
    let origin: String
    let localApiClient: ApiClient
    let localOrigin: String
    let isRacePinned: (Int) -> Bool

    /// Оффлайн-читаемые команды одной гонки, по стартовому номеру, затем id.
    func teamsForRace(_ raceId: Int) -> AsyncValueObservation<[Team]> {
        teamStore.observeTeamsForRace(raceId)
    }

    /// Оффлайн-читаемые категории одной гонки, по порядку сортировки, затем id.
    func categoriesForRace(_ raceId: Int) -> AsyncValueObservation<[Category]> {
        teamStore.observeCategoriesForRace(raceId)
    }

    /// Текущая выбранная команда или `nil`, когда ничего не выбрано.
    var selectedTeam: AsyncValueObservation<SelectedTeam?> {
        selectedTeamStore.observe()
    }

    /// Одна команда по id (`nil`, когда строка исчезает из локальной таблицы).
    func observeTeam(_ teamId: Int) -> AsyncValueObservation<Team?> {
        teamStore.observeTeamById(teamId)
    }

    /// Тянет `/app/race/<raceId>/teams/` с сохранённым ETag и на `200` заменяет команды + категории
    /// этой гонки, затем сохраняет новый ETag. Запись данных и запись ETag — две РАЗДЕЛЬНЫЕ
    /// транзакции намеренно (см. шапку файла). Pin-guard — до сети И повторно перед персистом `200`.
    /// Сериализацию параллельных refresh'ей одного ресурса репозиторий НЕ делает (как и `class`-репо в
    /// Kotlin — Mutex'а внутри нет) — это ответственность `SyncCoordinator` этапа 9.
    func refreshTeams(_ raceId: Int, source: SyncSource = .cloud) async throws -> RefreshResult {
        if source == .cloud && isRacePinned(raceId) { return .skipped }
        if source == .local && !isRacePinned(raceId) { return .skipped }

        let client: ApiClient
        let originKey: String
        let otherOriginKey: String
        switch source {
        case .cloud:
            client = apiClient
            originKey = origin
            otherOriginKey = localOrigin
        case .local:
            client = localApiClient
            originKey = localOrigin
            otherOriginKey = origin
        }

        let resource = teamsResource(raceId)
        let etag = try await syncMetaStore.getEtag(origin: originKey, resource: resource)
        switch await client.fetchTeams(raceId: raceId, etag: etag) {
        case let .success(data, responseEtag):
            // Повторная проверка guard'а: источник мог смениться, пока запрос был в полёте —
            // ответ потерявшего актуальность источника не должен затирать свежие строки другого.
            if source == .cloud && isRacePinned(raceId) { return .skipped }
            if source == .local && !isRacePinned(raceId) { return .skipped }
            // Оба origin делят таблицу: stale-ETag на не записываемом сейчас origin мог бы словить
            // 304 на следующем переключении и пропустить переперсист своих данных. Чистится ДО
            // замены, чтобы краш посреди записи не оставил чужой stale-ETag.
            try await syncMetaStore.deleteEtag(origin: otherOriginKey, resource: resource)
            try await teamStore.replaceAllForRace(
                raceId: raceId,
                categories: data.categories.map { $0.toCategory(raceId: raceId) },
                teams: data.teams.map { $0.toTeam(raceId: raceId) }
            )
            if let responseEtag {
                try await syncMetaStore.upsert(
                    SyncMeta(origin: originKey, resource: resource, etag: responseEtag)
                )
            }
            return .updated
        case .notModified:
            return .notModified
        case .forbidden:
            return .forbidden
        case let .error(code):
            return code == nil ? .offline : .httpError(code!)
        }
    }

    /// Записывает выбранную команду единственной строкой selected-team (перезаписывает прежний выбор).
    func selectTeam(raceId: Int, teamId: Int) async throws {
        try await selectedTeamStore.upsert(SelectedTeam(raceId: raceId, teamId: teamId))
    }

    /// Сбрасывает выбранную команду. Отладочно/для тестов — кэш команд/легенды/ETag не трогается.
    func clearSelectedTeam() async throws {
        try await selectedTeamStore.clear()
    }
}

/// Маппинг проводного DTO в доменный тип, штампуя `raceId` владельца. `order` → `sortOrder`.
private extension CategoryDto {
    func toCategory(raceId: Int) -> Category {
        Category(
            id: id,
            raceId: raceId,
            code: code,
            shortName: shortName,
            name: name,
            sortOrder: order
        )
    }
}

/// Маппинг проводного DTO в доменный тип; `members` становится JSON-колонкой. ms-время as-is.
private extension TeamDto {
    func toTeam(raceId: Int) -> Team {
        Team(
            id: id,
            raceId: raceId,
            teamname: teamname,
            startNumber: startNumber,
            categoryId: category2,
            ucount: ucount,
            paidPeople: paidPeople,
            startTime: startTime,
            finishTime: finishTime,
            members: members.map { TeamMemberItem(name: $0.name, numberInTeam: $0.numberInTeam) }
        )
    }
}
