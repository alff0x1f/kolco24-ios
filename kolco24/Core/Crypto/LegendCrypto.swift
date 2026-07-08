//
//  LegendCrypto.swift
//  kolco24
//
//  Чистый оффлайновый крипто-движок зашифрованной легенды (см. docs/API.md →
//  «Шифрование легенды»). Зеркало серверного референса
//  (`src/apps/mobile/crypto.py` + `legend_crypto.py`) байт-в-байт: SHA-256 `bid`,
//  HKDF-SHA256 вывод wrap-ключа, AES-256-GCM unseal и индирекция
//  `bundle_blob → content_key → enc`.
//
//  Kotlin-источник: `data/crypto/LegendCrypto.kt` (порт 1:1). Движок намеренно
//  persistence- и UI-free — потребляет минимальные value-типы (`UnlockTag`,
//  `EncBlob`), а не DTO/entity: карты строит репозиторий (этап 2).
//

import Foundation
import CryptoKit

/// Namespace-`enum`: чистые функции движка легенды.
enum LegendCrypto {

    /// `info` для HKDF-expand; ASCII-байты, как на сервере.
    private static let wrapInfo = Data("kp-wrap-v1".utf8)

    /// Длина GCM-тега в байтах (16-байтовый тег дописан в хвост `ct`).
    private static let gcmTagBytes = 16

    /// Размер выхода SHA-256 в байтах — он же длина HKDF `salt=None` (RFC 5869: HashLen нулей).
    private static let sha256Len = 32

    /// `bid = sha256(code).hexdigest()[:16]` — публичный идентификатор тега.
    static func bid(code: Data) -> String {
        String(HexBytes.encode(SHA256.hash(data: code)).prefix(16))
    }

    /// `wrap_key = HKDF-SHA256(code, salt=None, info="kp-wrap-v1", length=32)`.
    ///
    /// `salt=None` (RFC 5869 / Python `HKDF(salt=None)`) — это ровно `sha256Len` нулевых
    /// байт, **не** пустая соль: это разные ключи. CryptoKit `HKDF.deriveKey`
    /// выполняет extract+expand за один вызов.
    static func deriveWrapKey(code: Data) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: code),
            salt: Data(count: sha256Len),
            info: wrapInfo,
            outputByteCount: sha256Len
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// AES-256-GCM unseal `{iv, ct}`-конверта. `iv` = 12 байт (Base64), `ct` =
    /// `ciphertext || tag(16)` (Base64). GCM проверяет тег и `aad`; неверный
    /// ключ/`aad`/тампер → бросает (аналог Kotlin `GeneralSecurityException`).
    ///
    /// Ключевая ловушка порта: хвостовые 16 байт `ct` отрезаются как tag — это
    /// `SealedBox(nonce:ciphertext:tag:)`, **не** `combined:` (тот ждёт nonce в начале).
    static func open(key: Data, ivB64: String, ctB64: String, aad: Data) throws -> Data {
        guard let iv = Data(base64Encoded: ivB64) else {
            throw LegendCryptoError.invalidBase64
        }
        guard let ct = Data(base64Encoded: ctB64) else {
            throw LegendCryptoError.invalidBase64
        }
        guard ct.count >= gcmTagBytes else {
            throw LegendCryptoError.malformedCiphertext
        }
        let ciphertext = Data(ct.prefix(ct.count - gcmTagBytes))
        let tag = Data(ct.suffix(gcmTagBytes))
        let nonce = try AES.GCM.Nonce(data: iv)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
    }

    /// Полный оффлайновый unlock отсканированного тега. Чистая функция — без I/O,
    /// никогда не бросает:
    ///
    /// - `iv == nil && ct == nil` (тег открытого КП, нечего расшифровывать) → `.identityOnly`.
    /// - ровно один из `iv`/`ct` равен `nil` (битый конверт) → `.failed`.
    /// - иначе: открыть `bundle_blob` (`aad = bid`) → `{ "<cpId>": "<b64 content_key>" }`,
    ///   затем для каждого `cpId`, присутствующего в `encById`, открыть его `enc`
    ///   (`aad = str(cpId)`) → `{cost, description}` → `.revealed`.
    /// - любой крипто/парс-сбой → `.failed`.
    static func unlock(code: Data, tag: UnlockTag, encById: [Int: EncBlob]) -> UnlockResult {
        if tag.iv == nil && tag.ct == nil {
            return .identityOnly(checkpointId: tag.checkpointId)
        }
        guard let tagIv = tag.iv, let tagCt = tag.ct else {
            return .failed(reason: "malformed tag envelope: exactly one of iv/ct is null")
        }
        do {
            let bidStr = bid(code: code)
            let wrapKey = deriveWrapKey(code: code)
            let bundleJson = try open(key: wrapKey, ivB64: tagIv, ctB64: tagCt, aad: Data(bidStr.utf8))
            let bundle = try JSONDecoder().decode([String: String].self, from: bundleJson)
            var revealed = [RevealedCheckpoint]()
            for (cpIdStr, keyB64) in bundle {
                guard let cpId = Int(cpIdStr) else {
                    // Аналог Kotlin `cpIdStr.toInt()` → NumberFormatException → Failed.
                    throw LegendCryptoError.invalidCheckpointId
                }
                guard let enc = encById[cpId] else { continue }
                guard let contentKey = Data(base64Encoded: keyB64) else {
                    throw LegendCryptoError.invalidBase64
                }
                let plainJson = try open(
                    key: contentKey,
                    ivB64: enc.iv,
                    ctB64: enc.ct,
                    aad: Data(String(cpId).utf8)
                )
                let plain = try JSONDecoder().decode(RevealedPlain.self, from: plainJson)
                revealed.append(RevealedCheckpoint(id: cpId, cost: plain.cost, description: plain.description))
            }
            if revealed.isEmpty && !bundle.isEmpty {
                return .failed(reason: "no matching checkpoints in local cache — legend may be stale")
            }
            // Намеренное, допустимое расхождение с Kotlin (не байтовое, локальное). Kotlin
            // `bundle.mapNotNull` над insertion-ordered LinkedHashMap сохраняет порядок ключей
            // серверного JSON — но этот порядок сам по себе произволен (порядок серверной карты),
            // а `checkpointIds` — локальный результат расшифровки, который НИКОГДА не уходит на
            // сервер (не interop-байты) и на порядок которого не опирается ни один потребитель
            // (`classifyTag` берёт только `checkpointId`, KAT ищет по id). Swift `JSONDecoder` в
            // `[String: String]` теряет порядок ключей вовсе (был бы недетерминизм), поэтому
            // фиксируем детерминированно сортировкой по id КП — стабильнее произвольного порядка
            // Kotlin и достаточно по фиделити-исключению плана для локального порядка расшифровки.
            revealed.sort { $0.id < $1.id }
            return .revealed(checkpointId: tag.checkpointId, checkpoints: revealed)
        } catch {
            return .failed(reason: "\(error)")
        }
    }
}

/// Ошибки движка легенды (внутренние — `unlock` ловит и превращает в `.failed`).
enum LegendCryptoError: Error {
    case invalidBase64
    case malformedCiphertext
    case invalidCheckpointId
}

/// Зашифрованный `{iv, ct}`-конверт запертого КП (Base64), ключ — id КП в unlock-карте.
struct EncBlob: Equatable {
    let iv: String
    let ct: String
}

/// Минимальный срез записи `tags[]`, нужный движку: КП, который тег идентифицирует
/// (`checkpointId`), и конверт `bundle_blob` (`iv`/`ct`, оба `nil` для тегов открытых КП).
struct UnlockTag: Equatable {
    let checkpointId: Int
    let iv: String?
    let ct: String?
}

/// КП, чьи `{cost, description}` только что расшифрованы.
struct RevealedCheckpoint: Equatable {
    let id: Int
    let cost: Int
    let description: String?
}

/// Исход `LegendCrypto.unlock`.
enum UnlockResult: Equatable {
    /// Тег открыл один или несколько запертых КП (список может быть пуст, если открывает только неизвестные id).
    case revealed(checkpointId: Int, checkpoints: [RevealedCheckpoint])
    /// Тег открытого КП (`iv == nil`): только идентифицирует свой `checkpointId`, расшифровывать нечего.
    case identityOnly(checkpointId: Int)
    /// Крипто- или парс-сбой (неверный ключ, тампер, битый bundle).
    case failed(reason: String)
}

/// Расшифрованный plaintext `enc`-конверта запертого КП.
private struct RevealedPlain: Decodable {
    let cost: Int
    let description: String?
}
