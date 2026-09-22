//
//  MemberTagBind.swift
//  kolco24
//
//  Проводные типы `POST /app/race/<race_id>/member_tags/` — запись серверного кода на браслет
//  участника (iOS-first: у Android аналога нет, контракт — в плане
//  `docs/plans/20260923-member-chip-provisioning.md`). `MemberTagBindRequest` несёт нормализованный
//  `nfc_uid` и номер участника: `number == nil` — «UID уже в пуле, отдай код» (неизвестный UID →
//  `404`), с номером — «создай привязку». `MemberTagBindResponse` (201 при новом Tag / 200 при
//  идемпотентном повторе) — номер, `nfc_uid` и hex-`code`, который приложение пишет на браслет
//  (K24-запись типа `CHIP_TYPE_PARTICIPANT`). Незнакомые ключи игнорируются (дефолт `Codable`).
//
//  `Net/` — Foundation-only (grep-инвариант): без GRDB/UI.
//

import Foundation

/// Тело запроса `POST /app/race/<race_id>/member_tags/`: привязать `nfcUid` к участнику `number`
/// (или, при `nil`, получить код уже известного браслета).
struct MemberTagBindRequest: Encodable, Equatable {
    let nfcUid: String
    let number: Int?

    enum CodingKeys: String, CodingKey {
        case nfcUid = "nfc_uid"
        case number
    }

    /// Ручной `encode(to:)` в kotlinx-стиле: `number` кодируется **всегда**, `nil` — явным JSON
    /// `null` (синтезированный `Encodable` опустил бы ключ через `encodeIfPresent`).
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(nfcUid, forKey: .nfcUid)
        try c.encode(number, forKey: .number)
    }
}

/// Ответ `POST /app/race/<race_id>/member_tags/` (201 новый Tag / 200 идемпотентный повтор):
/// номер участника, нормализованный `nfc_uid` и hex-`code` для записи на браслет.
struct MemberTagBindResponse: Decodable, Equatable {
    let number: Int
    let nfcUid: String
    let code: String

    enum CodingKeys: String, CodingKey {
        case number
        case nfcUid = "nfc_uid"
        case code
    }
}
