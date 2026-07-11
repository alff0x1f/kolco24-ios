//
//  TagBind.swift
//  kolco24
//
//  Зеркало `data/api/dto/TagDtos.kt` — проводные типы `POST /app/race/<race_id>/tags/` (привязка
//  одного физического чипа по UID к КП). `TagBindRequest` несёт **стабильный** `Checkpoint.id`
//  (не человеко-читаемый номер) + нормализованный `nfc_uid`. `TagBindResponse` (201 при свежей
//  привязке / 200 при идемпотентном повторе) — `bid` тега, его `checkpoint_id`, человеко-читаемый
//  `number` КП, нормализованный `nfc_uid` и hex-`code`, который приложение пишет на чип, чтобы
//  распознавать КП оффлайн. Незнакомые ключи игнорируются (дефолт `Codable`).
//
//  `Net/` — Foundation-only (grep-инвариант): без GRDB/UI.
//

import Foundation

/// Тело запроса `POST /app/race/<race_id>/tags/`: привязать `nfcUid` к КП `checkpointId`.
struct TagBindRequest: Encodable, Equatable {
    let checkpointId: Int
    let nfcUid: String

    enum CodingKeys: String, CodingKey {
        case checkpointId = "checkpoint_id"
        case nfcUid = "nfc_uid"
    }
}

/// Ответ `POST /app/race/<race_id>/tags/` (201 свежий bind / 200 идемпотентный повтор): `bid`,
/// `checkpoint_id`, человеко-читаемый `number`, нормализованный `nfc_uid` и hex-`code` для записи.
struct TagBindResponse: Decodable, Equatable {
    let bid: String
    let checkpointId: Int
    let number: Int
    let nfcUid: String
    let code: String

    enum CodingKeys: String, CodingKey {
        case bid
        case checkpointId = "checkpoint_id"
        case number
        case nfcUid = "nfc_uid"
        case code
    }
}
