//
//  LegendRepository.swift
//  kolco24
//
//  Зеркало `data/LegendRepository.kt` 1:1 — единый источник правды по легенде одной гонки
//  (КП + NFC-теги). БД держит данные, сеть их только обновляет. UI читает
//  `checkpointsForRace`/`totalCostForRace`/`scoringCountForRace`/`tagsForRace`; `refreshLegend`
//  делает условный GET и на `200` целиком заменяет КП **и** теги этой гонки. Запертые КП
//  раскрываются **оффлайн** через `unlock` (сети нет).
//
//  Refresh-поток скопирован с `RaceRepository`/`TeamRepository` (ЭТАЛОН): РАЗДЕЛЬНЫЕ транзакции в
//  порядке «данные → потом ETag», `deleteEtag` другого origin — ДО замены. ОТЛИЧИЕ — персист идёт
//  в ТРИ store'а: `checkpointStore.replaceAllForRace` (preserve-reveal — раскрытый оффлайн КП не
//  залочивается снова), `tagStore.replaceAllForRace`, `legendMetaStore.upsert`. Как у Team/MemberTags
//  — pin-guard через `isRacePinned`-seam (до сети И повторно перед персистом `200`).
//
//  `import GRDB` — из-за реэкспорта `AsyncValueObservation` (тип GRDB); допустимо, файл под `Data/`.
//  Маппинг `CheckpointDto` (`enc != nil` → locked, `color ?? ""`, optional cost/description) и
//  `TagDto` — здесь. Крипто-движок (`LegendCrypto`, этап 1) делает сам unlock; репозиторий владеет
//  только DB-поиском, картой строк → `EncBlob` и персистом раскрытого.
//

import Foundation
import GRDB

/// Имя ресурса легенды одной гонки в `sync_meta` (партиция по origin).
private func legendResource(_ raceId: Int) -> String { "race/\(raceId)/legend" }

/// Единый источник правды по легенде одной гонки (КП + NFC-теги + агрегаты).
///
/// - Parameters:
///   - origin: base URL cloud-клиента — ключ-партиция ETag в `sync_meta`.
///   - localOrigin: base URL LAN-клиента — ключ-партиция ETag для LAN-фетчей.
///   - isRacePinned: `true`, когда `raceId` сейчас пришпилен к LAN. Cloud-refresh пришпиленной
///     гонки не персистит (устаревшее облачное зеркало не должно затирать свежие локальные строки),
///     и симметрично Local-refresh НЕ-пришпиленной гонки тоже не персистит. Сейчас всегда `false`;
///     этап 9 подставит lease.
struct LegendRepository {
    let apiClient: ApiClient
    let checkpointStore: CheckpointStore
    let tagStore: TagStore
    let legendMetaStore: LegendMetaStore
    let syncMetaStore: SyncMetaStore
    let origin: String
    let localApiClient: ApiClient
    let localOrigin: String
    let isRacePinned: (Int) -> Bool

    /// Оффлайн-читаемые КП одной гонки, по номеру, затем id.
    func checkpointsForRace(_ raceId: Int) -> AsyncValueObservation<[Checkpoint]> {
        checkpointStore.observeCheckpointsForRace(raceId)
    }

    /// Оффлайн-читаемая сумма `cost` **всех** КП гонки (открытых + запертых) — знаменатель
    /// прогресс-бара легенды. Эмитит `0`, пока первый `200` не заполнит `legend_meta` (строки нет
    /// ещё), схлопывая бар в 0% вместо перекоса; сервер всегда шлёт поле, так что это только
    /// пред-синк-окно.
    func totalCostForRace(_ raceId: Int) -> AsyncValueObservation<Int> {
        legendMetaStore.observeTotalCost(raceId)
    }

    /// Оффлайн-читаемое число **зачётных** КП (`cost > 0`, открытых + запертых) — знаменатель
    /// счётчика взятых КП, симметрично `totalCostForRace`. Эмитит `0` до первого `200`.
    func scoringCountForRace(_ raceId: Int) -> AsyncValueObservation<Int> {
        legendMetaStore.observeScoringCount(raceId)
    }

    /// Разовый снимок — перечитывается после оффлайн-`unlock`, чтобы взять только что раскрытую `cost`.
    func checkpointsSnapshot(_ raceId: Int) async throws -> [Checkpoint] {
        try await checkpointStore.getCheckpointsForRace(raceId)
    }

    /// Оффлайн-читаемые NFC-теги одной гонки (одна строка на привязанный чип).
    func tagsForRace(_ raceId: Int) -> AsyncValueObservation<[Tag]> {
        tagStore.observeTagsForRace(raceId)
    }

    /// Тянет `/app/race/<raceId>/legend/` с сохранённым ETag и на `200` заменяет КП **и** теги этой
    /// гонки, upsert'ит агрегаты, затем сохраняет новый ETag. Запись данных и запись ETag —
    /// РАЗДЕЛЬНЫЕ транзакции намеренно (краш между ними оставляет свежие данные со старым ETag →
    /// следующий refresh получит лишний `200` и самоизлечится). Pin-guard — до сети И повторно
    /// перед персистом `200`.
    func refreshLegend(_ raceId: Int, source: SyncSource = .cloud) async throws -> RefreshResult {
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

        let resource = legendResource(raceId)
        let etag = try await syncMetaStore.getEtag(origin: originKey, resource: resource)
        switch await client.fetchLegend(raceId: raceId, etag: etag) {
        case let .success(data, responseEtag):
            // Повторная проверка guard'а: источник мог смениться, пока запрос был в полёте —
            // ответ потерявшего актуальность источника не должен затирать свежие строки другого.
            if source == .cloud && isRacePinned(raceId) { return .skipped }
            if source == .local && !isRacePinned(raceId) { return .skipped }
            // Оба origin делят таблицу: stale-ETag на не записываемом сейчас origin мог бы словить
            // 304 на следующем переключении и пропустить переперсист своих данных. Чистится ДО
            // замены, чтобы краш посреди записи не оставил чужой stale-ETag.
            try await syncMetaStore.deleteEtag(origin: otherOriginKey, resource: resource)
            try await checkpointStore.replaceAllForRace(
                raceId: raceId,
                checkpoints: data.checkpoints.map { $0.toCheckpoint(raceId: raceId) }
            )
            try await tagStore.replaceAllForRace(
                raceId: raceId,
                tags: data.tags.map { $0.toTag(raceId: raceId) }
            )
            try await legendMetaStore.upsert(
                LegendMeta(raceId: raceId, totalCost: data.totalCost, scoringCount: data.scoringCount)
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

    /// Оффлайн-расшифровывает отсканированный тег и персистит раскрытый открытый текст КП.
    ///
    /// 16-байтовый NFC-[code] хэшируется в `bid` и ищется в `tags`; крипто делает движок
    /// `LegendCrypto` (метод владеет только DB-поиском, картой строк → `EncBlob` и персистом). Каждый
    /// раскрытый КП пишется через `checkpointStore.reveal` — `locked` сбрасывается в `false`.
    ///
    /// - Returns: `.unknown`, когда `bid` не совпал ни с одним тегом; `.identityOnly` для тега
    ///   открытого КП (расшифровывать нечего); `.revealed` (с id персистнутых КП) на успехе; либо
    ///   `.failed` на любом крипто/парс-сбое.
    func unlock(raceId: Int, code: Data) async throws -> UnlockOutcome {
        let bid = LegendCrypto.bid(code: code)
        guard let tag = try await tagStore.getByBid(bid: bid, raceId: raceId) else {
            return .unknown
        }
        if tag.iv == nil && tag.ct == nil {
            return .identityOnly(checkpointId: tag.checkpointId)
        }
        if tag.iv == nil || tag.ct == nil {
            return .failed(reason: "malformed tag envelope")
        }
        var encById = [Int: EncBlob]()
        for cp in try await checkpointStore.getCheckpointsForRace(raceId) {
            if let iv = cp.encIv, let ct = cp.encCt {
                encById[cp.id] = EncBlob(iv: iv, ct: ct)
            }
        }
        let result = LegendCrypto.unlock(
            code: code,
            tag: UnlockTag(checkpointId: tag.checkpointId, iv: tag.iv, ct: tag.ct),
            encById: encById
        )
        switch result {
        case let .revealed(checkpointId, checkpoints):
            for cp in checkpoints {
                try await checkpointStore.reveal(id: cp.id, cost: cp.cost, description: cp.description)
            }
            return .revealed(checkpointId: checkpointId, checkpointIds: checkpoints.map { $0.id })
        case let .identityOnly(checkpointId):
            return .identityOnly(checkpointId: checkpointId)
        case let .failed(reason):
            return .failed(reason: reason)
        }
    }
}

/// Маппинг проводного DTO в доменный КП, штампуя `raceId` владельца. Запертый КП приходит с
/// конвертом `enc` и без `cost`/`description`; открытый несёт контент напрямую. `enc != nil` —
/// сентинел `locked`. `color` — публичное race-scoped поле в обеих ветках, `nil` → `""`.
/// `CheckpointStore.replaceAllForRace` сохраняет любое прежнее оффлайн-раскрытие (preserve-reveal).
private extension CheckpointDto {
    func toCheckpoint(raceId: Int) -> Checkpoint {
        Checkpoint(
            id: id,
            raceId: raceId,
            number: number,
            cost: cost,
            type: type,
            description: description,
            locked: enc != nil,
            encIv: enc?.iv,
            encCt: enc?.ct,
            color: color ?? ""
        )
    }
}

/// Маппинг проводного DTO `tags[]` в доменный тег (1:1), штампуя `raceId` владельца.
private extension TagDto {
    func toTag(raceId: Int) -> Tag {
        Tag(
            raceId: raceId,
            bid: bid,
            checkpointId: checkpointId,
            checkMethod: checkMethod,
            iv: iv,
            ct: ct
        )
    }
}
