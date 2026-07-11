//
//  AuthDtos.swift
//  kolco24
//
//  Зеркало `data/api/dto/AuthDtos.kt` — проводные типы `POST /app/login/`. `LoginRequest` —
//  email/пароль организатора; `LoginResponse` — opaque 30-дневный bearer-токен + его `expires_at`
//  (фиксированный UTC-ISO с суффиксом `Z`, напр. `2026-07-21T14:03:00Z`). Незнакомые ключи
//  игнорируются (дефолт `Codable`). `logout` тела не имеет — своего DTO у него нет (пустой POST).
//

import Foundation

/// Тело запроса `POST /app/login/`.
struct LoginRequest: Encodable, Equatable {
    let email: String
    let password: String
}

/// Ответ успешного `POST /app/login/`: opaque bearer-токен + `expires_at` (UTC `Z`-ISO).
struct LoginResponse: Decodable, Equatable {
    let token: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }
}
