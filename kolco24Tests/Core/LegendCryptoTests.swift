//
//  LegendCryptoTests.swift
//  kolco24Tests
//
//  Server-vector-верификация `LegendCrypto` (зеркало `data/crypto/LegendCryptoTest.kt`,
//  5 кейсов). В отличие от `LegendCryptoSanityTests` (локальный seal → open, проверяет
//  только обвязку AES-GCM), эти ассерты пришпиливают движок к вектору, сгенерированному
//  серверным референсом (`src/apps/mobile/crypto.py` + `legend_crypto.py`) — единственное,
//  что доказывает HKDF (`salt=None`→32 нулевых байта), `bid` и AAD-interop байт-в-байт.
//
//  В Android-репо эти 4 вектор-теста стоят `@Ignore` с TODO(server-vector); здесь вектор
//  сгенерирован и зашит. Скрипт-генератор (`gen_legend_kat.py`) импортирует
//  `seal`/`derive_wrap_key` из серверного `crypto.py`; `bid` и сборка bundle-карты —
//  воспроизведённые однострочники из `legend_crypto.py` (они Django-ORM-связаны).
//

import Foundation
import Testing
@testable import kolco24

struct LegendCryptoTests {

    // region ───────── серверный KAT-вектор (сгенерирован gen_legend_kat.py) ─────────
    // code = 00 01 02 ... 0f (16 байт). Два запертых КП, достигаемых через цепочку
    // bundle → content_key → enc.
    private enum Vector {
        static let codeHex = "000102030405060708090a0b0c0d0e0f"
        static let expectedBid = "be45cb2605bf36be"
        static let expectedWrapKeyHex =
            "d60113b64cadc0829e11eb1b91f3a8c45c1a522f14ace89cb4067379c4d51a99"

        // bundle_blob-конверт для codeHex (aad = bid).
        static let tagIvB64 = "IvXiSPaYJsMfVBGh"
        static let tagCtB64 =
            "Vft9QueXUG3VYGXVh/GAB45AYvRWitc+tRqjNrandoEpdoFpV3uMqE5P4fuOpKjCUSp6jxuZXdzRG8xZ4j0n10UU1dJB75LtKCCt14lcWkvDnxrmouGByy2vDdIg76Nh8/CDf9KtY1sGZgevklB+JvdGBRGQWC5UyWW2BI+6"

        // Первый запертый КП (aad = "103").
        static let cp1Id = 103
        static let cp1EncIvB64 = "KqObDTP3AZKlMl6f"
        static let cp1EncCtB64 =
            "kQtwDqbS6Yo1+rnzTmdAvbrY6YS/GvWWREFUoCWL9WVn5hvqJul0U8BM1aKGT/NTUlMgyN5ZCIdVp7OY"
        static let cp1Cost = 5
        static let cp1Description = "Вершина"

        // Второй запертый КП (aad = "207") — покрывает полную цепочку content_key-индирекции.
        static let cp2Id = 207
        static let cp2EncIvB64 = "qrkoluxPBW5ZidNg"
        static let cp2EncCtB64 =
            "QQD2pxGZY19GcRP1mL+NTRiCqte8YfvloCikCQ8e/yin+Y0Fm2hWM9+gZOR+le9EbP5HTTS3vqXelA=="
        static let cp2Cost = 3
        static let cp2Description = "Родник"
    }
    // endregion

    private var code: Data { Data(HexBytes.decode(Vector.codeHex)) }

    @Test func bidMatchesServerVector() {
        #expect(LegendCrypto.bid(code: code) == Vector.expectedBid)
    }

    @Test func deriveWrapKeyMatchesServerVector() {
        let key = LegendCrypto.deriveWrapKey(code: code)
        #expect(HexBytes.encode(key) == Vector.expectedWrapKeyHex)
    }

    @Test func openDecryptsTagBundleToContentKeyMap() throws {
        let wrapKey = LegendCrypto.deriveWrapKey(code: code)
        let bidStr = LegendCrypto.bid(code: code)
        let bundleData = try LegendCrypto.open(
            key: wrapKey,
            ivB64: Vector.tagIvB64,
            ctB64: Vector.tagCtB64,
            aad: Data(bidStr.utf8)
        )
        let bundleJson = String(decoding: bundleData, as: UTF8.self)
        // JSON-объект: id открытого КП → его Base64 content-ключ.
        #expect(bundleJson.contains("\"\(Vector.cp1Id)\""))
        #expect(bundleJson.contains("\"\(Vector.cp2Id)\""))
    }

    @Test func unlockRevealsCheckpointPlaintextFromVector() {
        let tag = UnlockTag(checkpointId: Vector.cp1Id, iv: Vector.tagIvB64, ct: Vector.tagCtB64)
        let result = LegendCrypto.unlock(
            code: code,
            tag: tag,
            encById: [
                Vector.cp1Id: EncBlob(iv: Vector.cp1EncIvB64, ct: Vector.cp1EncCtB64),
                Vector.cp2Id: EncBlob(iv: Vector.cp2EncIvB64, ct: Vector.cp2EncCtB64),
            ]
        )
        guard case let .revealed(checkpointId, checkpoints) = result else {
            Issue.record("expected .revealed, got \(result)")
            return
        }
        #expect(checkpointId == Vector.cp1Id)

        let cp1 = checkpoints.first { $0.id == Vector.cp1Id }
        #expect(cp1?.cost == Vector.cp1Cost)
        #expect(cp1?.description == Vector.cp1Description)

        // Второй КП пройден через content_key-индирекцию — полная цепочка.
        let cp2 = checkpoints.first { $0.id == Vector.cp2Id }
        #expect(cp2?.cost == Vector.cp2Cost)
        #expect(cp2?.description == Vector.cp2Description)
    }

    @Test func unlockFailsOnStaleLegendWithNoMatchingCheckpoints() {
        // Валидный bundle открывается, но encById пуст → revealed пуст при непустом
        // bundle → Failed («legend may be stale»). Это НЕ GCM-тампер (тот покрыт
        // LegendCryptoSanityTests.unlockFailsOnTamperedCiphertext) — здесь ветка
        // stale-legend. Ассерт: любая ветка Failed.
        let tag = UnlockTag(checkpointId: Vector.cp1Id, iv: Vector.tagIvB64, ct: Vector.tagCtB64)
        let result = LegendCrypto.unlock(code: code, tag: tag, encById: [:])
        guard case .failed = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
    }
}
