//
//  MemberTagsRepository.swift
//  kolco24
//
//  Зеркало `data/MemberTagsRepository.kt` 1:1 — единый источник правды по пулу NFC-браслетов
//  участников одной гонки (`number → nfc_uid`, офлайн-идентификация скана). БД держит данные, сеть
//  их только обновляет. UI/bind-поток читает `observeForRace`/`findByUid`; `refreshMemberTags`
//  делает условный GET и на `200` целиком заменяет строки этой гонки.
//
//  Refresh-поток и pin-guard — как у `TeamRepository`. ОТЛИЧИЕ — synced-маркер: доп. ресурс
//  `sync_meta["race/<id>/member_tags/synced"] = "1"`, который пишется на любой успешный `200`, даже
//  когда сервер не прислал ETag — отличает «пул пуст, но синк был» от «синка не было» (переживает
//  пересоздание экрана). `hasBeenSynced`/`observeHasBeenSynced` проверяют ЛИБО ETag-ресурс, ЛИБО
//  synced-маркер. Оба маркера другого origin чистятся ДО замены (как ETag у Team).
//
//  `import GRDB` — из-за реэкспорта `AsyncValueObservation`; допустимо, файл под `Data/`.
//  Маппинг `MemberTagDto` → `Model/MemberTag` — здесь.
//

import GRDB

/// Имя ресурса пула member-тегов одной гонки в `sync_meta` (партиция по origin).
private func memberTagsResource(_ raceId: Int) -> String { "race/\(raceId)/member_tags" }

/// Отдельный synced-маркер, пишется на каждый успешный `200`, даже когда сервер не прислал `ETag`:
/// `hasBeenSynced` проверяет этот ключ, чтобы пустой пул без ETag тоже считался «синхронизированным»
/// после пересоздания экрана.
private func memberTagsSyncedResource(_ raceId: Int) -> String { "race/\(raceId)/member_tags/synced" }

/// Единый источник правды по пулу member-тегов одной гонки.
///
/// - Parameters:
///   - origin: base URL cloud-клиента — ключ-партиция ETag в `sync_meta`.
///   - localOrigin: base URL LAN-клиента — ключ-партиция ETag для LAN-фетчей.
///   - isRacePinned: `true`, когда `raceId` сейчас пришпилен к LAN (см. `TeamRepository`). Сейчас
///     всегда `false`; этап 9 подставит lease.
struct MemberTagsRepository {
    let apiClient: ApiClient
    let memberTagStore: MemberTagStore
    let syncMetaStore: SyncMetaStore
    let origin: String
    let localApiClient: ApiClient
    let localOrigin: String
    let isRacePinned: (Int) -> Bool

    /// Оффлайн-читаемый пул member-тегов одной гонки, по номеру участника, затем uid.
    func observeForRace(_ raceId: Int) -> AsyncValueObservation<[MemberTag]> {
        memberTagStore.observeForRace(raceId)
    }

    /// Резолвит просканированный/нормализованный `nfcUid` по пулу гонки (`nil`, если не в пуле).
    func findByUid(raceId: Int, nfcUid: String) async throws -> MemberTag? {
        try await memberTagStore.findByUid(raceId: raceId, nfcUid: nfcUid)
    }

    /// `true`, если пул member-тегов для `raceId` хотя бы раз успешно тянулся из origin'а `source`.
    /// Bind-лист отличает «пул ещё не синхронизирован» от «пул реально пуст». Проверяет ЛИБО
    /// ETag-ресурс (пишется, когда сервер прислал `ETag`), ЛИБО synced-маркер (пишется на любой
    /// успешный `200`). Оба отсутствуют только если успешного фетча для этой гонки/источника не было.
    func hasBeenSynced(raceId: Int, source: SyncSource = .cloud) async throws -> Bool {
        let originKey = source == .cloud ? origin : localOrigin
        let etag = try await syncMetaStore.getEtag(origin: originKey, resource: memberTagsResource(raceId))
        if etag != nil { return true }
        let marker = try await syncMetaStore.getEtag(
            origin: originKey, resource: memberTagsSyncedResource(raceId)
        )
        return marker != nil
    }

    /// Реактивный близнец `hasBeenSynced` — эмитит свежее значение на каждый успешный
    /// `refreshMemberTags` (свой или с другого экрана/warm-up'а), так что UI, начавший наблюдать во
    /// время фетча в полёте, не залипает на устаревшем `false`.
    func observeHasBeenSynced(raceId: Int, source: SyncSource = .cloud) -> AsyncValueObservation<Bool> {
        let originKey = source == .cloud ? origin : localOrigin
        return syncMetaStore.observeEtagsExist(
            origin: originKey,
            resource1: memberTagsResource(raceId),
            resource2: memberTagsSyncedResource(raceId)
        )
    }

    /// Тянет `/app/race/<raceId>/member_tags/` с сохранённым ETag и на `200` заменяет строки этой
    /// гонки, затем сохраняет новый ETag (или synced-маркер, если ETag'а нет). Данные и ETag — две
    /// РАЗДЕЛЬНЫЕ транзакции. Pin-guard — до сети И повторно перед персистом `200`.
    /// Сериализацию параллельных refresh'ей одного ресурса репозиторий НЕ делает (как и `class`-репо в
    /// Kotlin — Mutex'а внутри нет) — это ответственность `SyncCoordinator` этапа 9.
    func refreshMemberTags(_ raceId: Int, source: SyncSource = .cloud) async throws -> RefreshResult {
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

        let resource = memberTagsResource(raceId)
        let etag = try await syncMetaStore.getEtag(origin: originKey, resource: resource)
        switch await client.fetchMemberTags(raceId: raceId, etag: etag) {
        case let .success(data, responseEtag):
            if source == .cloud && isRacePinned(raceId) { return .skipped }
            if source == .local && !isRacePinned(raceId) { return .skipped }
            // Оба origin делят таблицу: stale-ETag ИЛИ synced-маркер на не записываемом сейчас origin
            // мог бы словить 304 (ETag) или ложный hasBeenSynced() (маркер) на следующем переключении
            // и пропустить пересинк над строками, которые эта запись заменяет. Чистятся ДО замены,
            // чтобы краш посреди записи не оставил ни одного stale-маркера.
            try await syncMetaStore.deleteEtag(origin: otherOriginKey, resource: resource)
            try await syncMetaStore.deleteEtag(
                origin: otherOriginKey, resource: memberTagsSyncedResource(raceId)
            )
            try await memberTagStore.replaceAllForRace(
                raceId: raceId,
                tags: data.memberTags.map { $0.toMemberTag(raceId: raceId) }
            )
            if let responseEtag {
                try await syncMetaStore.upsert(
                    SyncMeta(origin: originKey, resource: resource, etag: responseEtag)
                )
            } else {
                // ETag'а нет: пишем synced-маркер, чтобы hasBeenSynced() вернул true после
                // пересоздания экрана даже для пустого пула (ответ 200 без ETag — легитимный ответ
                // сервера, а не состояние «ещё не синхронизировано»).
                try await syncMetaStore.upsert(
                    SyncMeta(origin: originKey, resource: memberTagsSyncedResource(raceId), etag: "1")
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

/// Маппинг `member_tags[]` DTO в доменный тип, штампуя `raceId` владельца.
private extension MemberTagDto {
    func toMemberTag(raceId: Int) -> MemberTag {
        MemberTag(raceId: raceId, nfcUid: nfcUid, number: number)
    }
}
