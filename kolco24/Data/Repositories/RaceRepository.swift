//
//  RaceRepository.swift
//  kolco24
//
//  Зеркало `data/RaceRepository.kt` 1:1 — единый источник правды по списку гонок: БД держит
//  данные, сеть их только обновляет. UI читает `races`; `refreshRaces` делает условный GET и на
//  `200` целиком заменяет локальную таблицу. Гонки глобальны (не привязаны к raceId) — в отличие
//  от остальных трёх репозиториев здесь НЕТ pin-guard'а.
//
//  ЭТАЛОН refresh-потока (остальные репозитории копируют его): три РАЗДЕЛЬНЫЕ транзакции в порядке
//  «данные → потом ETag». Краш между ними оставляет свежие данные со старым/отсутствующим ETag
//  (следующий refresh получит лишний `200` и самоизлечится); обратный порядок навсегда пришпилил бы
//  новый ETag к старым данным. `deleteEtag` другого origin — ДО замены (не после), чтобы краш
//  посреди записи не оставил чужой stale-ETag, маскирующий то, что эта запись не легла.
//
//  `import GRDB` — из-за реэкспорта `AsyncValueObservation` в `races` (тип GRDB); допустимо, файл под
//  `Data/`. Персист идёт через store-структуры этапа 2. Маппинг `RaceDto` → `Model/Race` — здесь.
//

import GRDB

/// Имя ресурса гонок в `sync_meta` (партиция по origin).
private let resourceRaces = "races"

/// Исход `RaceRepository.refreshRaces` (и остальных refresh-репозиториев). `Error(nil)` из сети
/// (офлайн / оборванное соединение) → `.offline`; `Error(code)` → `.httpError(code)`. `.skipped` —
/// cloud-refresh пропущен из-за pin'а на LAN (у Race не возникает — оставлен для единообразия enum'а).
enum RefreshResult: Equatable {
    case updated
    case notModified
    case offline
    case forbidden
    case httpError(Int)
    case skipped
}

/// Единый источник правды по списку гонок. Оффлайн-читаемый `races` + сетевой `refreshRaces`.
///
/// - Parameters:
///   - origin: base URL, к которому привязаны данные — ключ-партиция ETag в `sync_meta`.
///   - localOrigin: base URL LAN-клиента — ключ-партиция ETag для LAN-фетчей.
struct RaceRepository {
    let apiClient: ApiClient
    let raceStore: RaceStore
    let syncMetaStore: SyncMetaStore
    let origin: String
    let localApiClient: ApiClient
    let localOrigin: String

    /// Оффлайн-читаемый список гонок, новые сверху (`ORDER BY date DESC, id DESC`).
    var races: AsyncValueObservation<[Race]> {
        raceStore.observeRaces()
    }

    /// Тянет `/app/races/` с сохранённым ETag и на `200` целиком заменяет таблицу, затем сохраняет
    /// новый ETag. Запись данных и запись ETag — две РАЗДЕЛЬНЫЕ транзакции намеренно (см. шапку файла).
    func refreshRaces(source: SyncSource = .cloud) async throws -> RefreshResult {
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

        let etag = try await syncMetaStore.getEtag(origin: originKey, resource: resourceRaces)
        switch await client.fetchRaces(etag: etag) {
        case let .success(data, responseEtag):
            // Оба origin делят одну таблицу: stale-ETag на не записываемом сейчас origin мог бы
            // словить 304 на следующем переключении и пропустить переперсист своих данных.
            // Чистится ДО замены (не после), чтобы краш посреди записи не оставил чужой stale-ETag.
            try await syncMetaStore.deleteEtag(origin: otherOriginKey, resource: resourceRaces)
            try await raceStore.replaceAll(data.map { $0.toRace() })
            if let responseEtag {
                try await syncMetaStore.upsert(
                    SyncMeta(origin: originKey, resource: resourceRaces, etag: responseEtag)
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
}

/// Маппинг проводного DTO в доменный тип (он же — persist-модель).
private extension RaceDto {
    func toRace() -> Race {
        Race(
            id: id,
            name: name,
            slug: slug,
            date: date,
            dateEnd: dateEnd,
            place: place,
            regStatus: regStatus
        )
    }
}
