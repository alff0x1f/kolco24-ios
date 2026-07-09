//
//  MemberTagsResponse.swift
//  kolco24
//
//  Зеркало `data/api/dto/MemberTagsResponse.kt` 1:1: проводной payload
//  `GET /app/race/<id>/member_tags/` — пул NFC-браслетов участников (офлайн-идентификация скана:
//  `nfc_uid → number`). Маппинг в `Model/MemberTag` делает `MemberTagsRepository` (задача 6).
//

/// Верхнеуровневый payload `GET /app/race/<id>/member_tags/`.
struct MemberTagsResponse: Codable, Equatable {
    let memberTags: [MemberTagDto]

    enum CodingKeys: String, CodingKey {
        case memberTags = "member_tags"
    }
}

/// Один слот пула NFC-чипов: нормализованный UID чипа → номер участника, за которым он закреплён.
/// Серверного `id` нет — слот идентифицируется по `nfc_uid` (уже trimmed + UPPERCASE на сервере).
struct MemberTagDto: Codable, Equatable {
    let number: Int
    let nfcUid: String

    enum CodingKeys: String, CodingKey {
        case number
        case nfcUid = "nfc_uid"
    }
}
