//
//  AuthDtos.swift
//  kolco24
//
//  Зеркало `data/api/dto/AuthDtos.kt` — проводные типы `POST /app/login/`. `LoginRequest` —
//  email/пароль организатора; `LoginResponse` — opaque 30-дневный bearer-токен + его `expires_at`
//  (фиксированный UTC-ISO с суффиксом `Z`, напр. `2026-07-21T14:03:00Z`) + `admin_race_ids` (id гонок,
//  где пользователь админ; только подсказка UI, нет ключа у старого сервера → `[]`). Незнакомые ключи
//  игнорируются (дефолт `Codable`). `logout` тела не имеет — своего DTO у него нет (пустой POST).
//

import Foundation

/// Тело запроса `POST /app/login/`.
struct LoginRequest: Encodable, Equatable {
    let email: String
    let password: String
}

/// Ответ успешного `POST /app/login/`: opaque bearer-токен + `expires_at` (UTC `Z`-ISO) + id гонок,
/// где пользователь `RaceAdmin(role=ADMIN)`.
struct LoginResponse: Decodable, Equatable {
    let token: String
    let expiresAt: String
    let adminRaceIds: [Int]

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
        case adminRaceIds = "admin_race_ids"
    }
}

extension LoginResponse {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decode(String.self, forKey: .token)
        expiresAt = try container.decode(String.self, forKey: .expiresAt)
        adminRaceIds = try container.decodeIfPresent([Int].self, forKey: .adminRaceIds) ?? []
    }
}
