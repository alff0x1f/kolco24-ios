//
//  Signing.swift
//  kolco24
//
//  Kotlin-источник: верх `data/api/AppSignatureInterceptor.kt` (4 свободные декларации).
//  Сам OkHttp-`Interceptor` не портируется — URLSession-аналог появится в этапе 3.
//

import Foundation
import CryptoKit

/// hex SHA-256 пустого тела — константа для GET / запросов без тела (см. docs/API.md).
let EMPTY_BODY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

/// lower-case hex SHA-256 от `bytes`.
func sha256Hex(_ bytes: Data) -> String {
    HexBytes.encode(SHA256.hash(data: bytes))
}

/// Строит каноническую строку, которую сервер ожидает подписанной: четыре части через `\n`
/// (без завершающего перевода строки). См. docs/API.md.
///
/// `fullPath` — путь, который реально отправляется, включая завершающий слэш и query-строку,
/// если есть. `bodyHash` — lower-hex SHA-256 тела запроса (`EMPTY_BODY_SHA256` для GET / пустых тел).
func buildCanonical(method: String, fullPath: String, ts: String, bodyHash: String) -> String {
    [method.uppercased(), fullPath, ts, bodyHash].joined(separator: "\n")
}

/// lower-case hex HMAC-SHA256 от `canonical` с ключом `secret` (оба UTF-8).
func sign(secret: String, canonical: String) -> String {
    let key = SymmetricKey(data: Data(secret.utf8))
    let mac = HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: key)
    return HexBytes.encode(mac)
}
