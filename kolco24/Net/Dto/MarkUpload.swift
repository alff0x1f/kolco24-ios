//
//  MarkUpload.swift
//  kolco24
//
//  Зеркало `data/api/dto/MarkDtos.kt` — проводные типы `POST /app/race/<raceId>/marks/`.
//  Тело — батч взятий одной команды; идемпотентный upsert по клиентскому `MarkDto.id`,
//  так что повторная отправка уже принятого батча безопасна.
//
//  **Ловушки маппинга** (НЕ прямой snake_case имён Swift-полей `Mark`): `cp_nfc_uid ← cpUid`,
//  `cp_code ← cpCode`, `wall_ms ← takenAt`, `trusted_ms ← trustedTakenAt`,
//  `elapsed_at ← elapsedRealtimeAt`. Массив `present[]` **мёржится поверх `Mark.present`**
//  (истина состава) — см. `MarkDto(from:)`.
//
//  Nullable-кодирование воспроизводит то, как реально шлёт Android (kotlinx.serialization с
//  `encodeDefaults = false`, `explicitNulls = true`): скаляры **без** default-значения
//  (`trusted_ms`, `elapsed_at`, `boot_count`, `present[].nfc_uid`/`code`, все nullable-поля
//  `TakeLocationDto`) кодируются явным JSON `null` (ручной `encode`, не `encodeIfPresent`); а
//  `location` в Kotlin имеет default `= null` и при отсутствии фикса **опускается целиком**
//  (ключа нет) — для него `encodeIfPresent`.
//

import Foundation

/// Тело запроса `POST /app/race/<raceId>/marks/`. В отличие от track-загрузки несёт
/// `source_install_id` (провенанс устройства, тот же UUID, что заголовок `X-Install-Id`, но
/// продублированный в **подписанное** тело) — требуется контрактом marks, чтобы сервер дедупил
/// два телефона одной команды и мог переатрибутировать неверно-командный рапорт.
struct MarkUploadRequest: Encodable {
    let teamId: Int
    let sourceInstallId: String
    let marks: [MarkDto]

    enum CodingKeys: String, CodingKey {
        case teamId = "team_id"
        case sourceInstallId = "source_install_id"
        case marks
    }
}

/// Одно взятие КП на проводе. Имена полей отличаются от `Mark` — см. ловушки маппинга в шапке файла.
struct MarkDto: Encodable {
    let id: String
    let checkpointId: Int
    let method: String
    let cpCode: String
    let cpNfcUid: String
    let present: [PresentMemberDto]
    let expectedCount: Int
    let complete: Bool
    let trustedMs: Int64?
    let wallMs: Int64
    let elapsedAt: Int64?
    let bootCount: Int?
    let location: TakeLocationDto?

    enum CodingKeys: String, CodingKey {
        case id
        case checkpointId = "checkpoint_id"
        case method
        case cpCode = "cp_code"
        case cpNfcUid = "cp_nfc_uid"
        case present
        case expectedCount = "expected_count"
        case complete
        case trustedMs = "trusted_ms"
        case wallMs = "wall_ms"
        case elapsedAt = "elapsed_at"
        case bootCount = "boot_count"
        case location
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(checkpointId, forKey: .checkpointId)
        try c.encode(method, forKey: .method)
        try c.encode(cpCode, forKey: .cpCode)
        try c.encode(cpNfcUid, forKey: .cpNfcUid)
        try c.encode(present, forKey: .present)
        try c.encode(expectedCount, forKey: .expectedCount)
        try c.encode(complete, forKey: .complete)
        // No-default скаляры: явный JSON null (не encodeIfPresent).
        try c.encode(trustedMs, forKey: .trustedMs)
        try c.encode(wallMs, forKey: .wallMs)
        try c.encode(elapsedAt, forKey: .elapsedAt)
        try c.encode(bootCount, forKey: .bootCount)
        // `location` имеет Kotlin-default `= null` → при nil ключ опускается целиком.
        try c.encodeIfPresent(location, forKey: .location)
    }
}

/// Один присутствовавший участник на проводе, по **физической идентичности чипа**. Сервер сам
/// резолвит `uid/code → участник` в своём пуле, не доверяя клиентскому `number`. Sentinel-запись
/// (`nfc_uid = null`, `code = null`, `number = 0`) означает «этот слот в `present`, но снимок не
/// снят» (legacy-строка до появления `presentDetails`) — **не** реальный номер участника.
struct PresentMemberDto: Encodable {
    let nfcUid: String?
    let code: String?
    let number: Int
    let numberInTeam: Int

    enum CodingKeys: String, CodingKey {
        case nfcUid = "nfc_uid"
        case code
        case number
        case numberInTeam = "number_in_team"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // No-default nullable: явный JSON null.
        try c.encode(nfcUid, forKey: .nfcUid)
        try c.encode(code, forKey: .code)
        try c.encode(number, forKey: .number)
        try c.encode(numberInTeam, forKey: .numberInTeam)
    }
}

/// Анти-чит-координата места взятия (вложена, чтобы `gps_time_ms`/`elapsed_at` фикса не
/// коллидировали с одноимёнными временами самого взятия). Строится из 7 `loc*`-полей `Mark`;
/// весь объект `null`, когда фикса не было (`locLat == nil`). `accuracy` и «возраст фикса»
/// (`mark.elapsed_at − location.elapsed_at`) — ключевые анти-чит-сигналы.
struct TakeLocationDto: Encodable {
    let lat: Double
    let lon: Double
    let accuracy: Float?
    let altitude: Double?
    let verticalAccuracy: Float?
    let gpsTimeMs: Int64?
    let elapsedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case lat
        case lon
        case accuracy
        case altitude
        case verticalAccuracy = "vertical_accuracy"
        case gpsTimeMs = "gps_time_ms"
        case elapsedAt = "elapsed_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lat, forKey: .lat)
        try c.encode(lon, forKey: .lon)
        // No-default nullable-поля фикса: явный JSON null.
        try c.encode(accuracy, forKey: .accuracy)
        try c.encode(altitude, forKey: .altitude)
        try c.encode(verticalAccuracy, forKey: .verticalAccuracy)
        try c.encode(gpsTimeMs, forKey: .gpsTimeMs)
        try c.encode(elapsedAt, forKey: .elapsedAt)
    }
}

/// Ответ `POST /app/race/<raceId>/marks/`: клиентские `id`, которые сервер принял (upsert'нул).
struct MarkUploadResponse: Decodable, Equatable {
    let accepted: [String]
}

extension MarkDto {
    /// Чистый маппер `Mark → MarkDto`. Массив `present[]` **мёржится поверх `Mark.present`**
    /// (скоринговая истина), так что ни один участник не теряется: каждый `numberInTeam` из
    /// `present` становится `PresentMemberDto`, обогащённым совпавшим `MarkMemberSnapshot`, а при
    /// его отсутствии — sentinel (`nfc_uid = nil`, `number = 0`). Поэтому legacy-строка
    /// (`presentDetails == nil`) всё равно выгружает всех участников sentinel'ами, а частично
    /// снятая строка обогащает только те слоты, для которых есть снимок. `location` строится из 7
    /// `loc*`-полей или `nil`, когда `locLat == nil` (нет фикса).
    init(from mark: Mark) {
        let byNum = Dictionary(
            (mark.presentDetails ?? []).map { ($0.numberInTeam, $0) },
            uniquingKeysWith: { _, last in last }
        )
        let presentDtos = mark.present.map { num -> PresentMemberDto in
            if let snap = byNum[num] {
                return PresentMemberDto(
                    nfcUid: snap.nfcUid,
                    code: snap.code,
                    number: snap.number,
                    numberInTeam: snap.numberInTeam
                )
            }
            return PresentMemberDto(nfcUid: nil, code: nil, number: 0, numberInTeam: num)
        }
        let location: TakeLocationDto?
        if let lat = mark.locLat, let lon = mark.locLon {
            location = TakeLocationDto(
                lat: lat,
                lon: lon,
                accuracy: mark.locAccuracy,
                altitude: mark.locAltitude,
                verticalAccuracy: mark.locVerticalAccuracy,
                gpsTimeMs: mark.locGpsTimeMs,
                elapsedAt: mark.locElapsedRealtimeAt
            )
        } else {
            location = nil
        }
        self.init(
            id: mark.id,
            checkpointId: mark.checkpointId,
            method: mark.method,
            cpCode: mark.cpCode,
            cpNfcUid: mark.cpUid,
            present: presentDtos,
            expectedCount: mark.expectedCount,
            complete: mark.complete,
            trustedMs: mark.trustedTakenAt,
            wallMs: mark.takenAt,
            elapsedAt: mark.elapsedRealtimeAt,
            bootCount: mark.bootCount,
            location: location
        )
    }
}
