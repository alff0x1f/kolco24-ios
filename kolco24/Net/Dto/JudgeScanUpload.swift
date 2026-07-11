//
//  JudgeScanUpload.swift
//  kolco24
//
//  Зеркало `data/api/dto/JudgeScanDtos.kt` — проводные типы `POST /app/race/<raceId>/judge_scans/`.
//  Тело — батч судейских пиков старта/финиша одной **гонки** (по всем командам); идемпотентный upsert
//  по клиентскому `JudgeScanDto.id`, так что повторная отправка уже принятого батча безопасна.
//
//  **В отличие от marks-загрузки** запрос несёт `source_install_id`, но **НЕ** несёт `team_id` —
//  судейская станция сканит все команды гонки, скоуп — только `raceId` (он в URL). Провенанс
//  устройства (`source_install_id`, тот же UUID, что заголовок `X-Install-Id`) дублируется в
//  **подписанное** тело, чтобы сервер дедупил пики двух телефонов одного судьи.
//
//  Nullable-кодирование воспроизводит то, как реально шлёт Android (kotlinx.serialization с
//  `encodeDefaults = false`, `explicitNulls = true`): скаляры **без** default-значения (`trusted_ms`,
//  `boot_count`) кодируются явным JSON `null` (ручной `encode`, не `encodeIfPresent`) — отсюда
//  рукописный `encode(to:)` вместо синтезированного.
//
//  **Ловушки маппинга** (НЕ прямой snake_case имён Swift-полей `JudgeScan`): `wall_ms ← takenAt`,
//  `trusted_ms ← trustedTakenAt`, `elapsed_at ← elapsedRealtimeAt` — см. `init(from:)`.
//

import Foundation

/// Тело запроса `POST /app/race/<raceId>/judge_scans/`. **Без `team_id`** (судейская станция
/// сканит все команды; `raceId` — в URL); несёт `source_install_id` (провенанс устройства).
struct JudgeScanUploadRequest: Encodable {
    let sourceInstallId: String
    let scans: [JudgeScanDto]

    enum CodingKeys: String, CodingKey {
        case sourceInstallId = "source_install_id"
        case scans
    }
}

/// Один судейский пик на проводе. Имена полей отличаются от `JudgeScan` — см. ловушки маппинга в
/// шапке файла. `participantNumber` — **глобальный** номер участника; `id` (клиентский UUID) —
/// ключ идемпотентности.
struct JudgeScanDto: Encodable {
    let id: String
    let eventType: String
    let participantNumber: Int
    let nfcUid: String
    let wallMs: Int64
    let trustedMs: Int64?
    let elapsedAt: Int64
    let bootCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case eventType = "event_type"
        case participantNumber = "participant_number"
        case nfcUid = "nfc_uid"
        case wallMs = "wall_ms"
        case trustedMs = "trusted_ms"
        case elapsedAt = "elapsed_at"
        case bootCount = "boot_count"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(eventType, forKey: .eventType)
        try c.encode(participantNumber, forKey: .participantNumber)
        try c.encode(nfcUid, forKey: .nfcUid)
        try c.encode(wallMs, forKey: .wallMs)
        // No-default nullable-поля: явный JSON null (не encodeIfPresent).
        try c.encode(trustedMs, forKey: .trustedMs)
        try c.encode(elapsedAt, forKey: .elapsedAt)
        try c.encode(bootCount, forKey: .bootCount)
    }
}

/// Ответ `POST /app/race/<raceId>/judge_scans/`: клиентские `id`, которые сервер принял (upsert'нул).
struct JudgeScanUploadResponse: Decodable, Equatable {
    let accepted: [String]
}

extension JudgeScanDto {
    /// Чистый маппер `JudgeScan → JudgeScanDto`. Дропает локальные `raceId` (в URL),
    /// `sourceInstallId` (в конверте запроса), `uploaded*` (флаги локальны) и переименовывает
    /// `wall_ms ← takenAt`, `trusted_ms ← trustedTakenAt`, `elapsed_at ← elapsedRealtimeAt`.
    /// Зеркало `JudgeScanEntity.toDto`.
    init(from scan: JudgeScan) {
        self.init(
            id: scan.id,
            eventType: scan.eventType,
            participantNumber: scan.participantNumber,
            nfcUid: scan.nfcUid,
            wallMs: scan.takenAt,
            trustedMs: scan.trustedTakenAt,
            elapsedAt: scan.elapsedRealtimeAt,
            bootCount: scan.bootCount
        )
    }
}
