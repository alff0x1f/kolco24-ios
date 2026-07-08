//
//  LegendCryptoSanityTests.swift
//  kolco24Tests
//
//  Внутренние sanity-тесты `LegendCrypto` (зеркало `data/crypto/LegendCryptoSanityTest.kt`,
//  7 кейсов). Они запечатывают данные локально и проверяют обвязку AES-GCM +
//  индирекцию bundle/content-key на round-trip — но НЕ проверяют interop HKDF/`bid`/AAD
//  с сервером (это делает вектор-тест в `LegendCryptoTests`).
//

import Foundation
import CryptoKit
import Testing
@testable import kolco24

struct LegendCryptoSanityTests {

    /// Зеркало `LegendCrypto.open` для направления шифрования — test-only `seal`.
    /// Формат совместим с `open`: `iv` отдельно, `ct = ciphertext || tag(16)`.
    private func seal(key: Data, plaintext: Data, aad: Data) -> EncBlob {
        let box = try! AES.GCM.seal(plaintext, using: SymmetricKey(data: key), authenticating: aad)
        let ct = box.ciphertext + box.tag
        return EncBlob(iv: Data(box.nonce).base64EncodedString(), ct: ct.base64EncodedString())
    }

    @Test func bidIs16HexCharsAndDeterministic() {
        let code = Data((0..<16).map { UInt8($0) })
        let bid = LegendCrypto.bid(code: code)
        #expect(bid.count == 16)
        #expect(bid.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(bid == LegendCrypto.bid(code: code))
    }

    @Test func deriveWrapKeyIs32Bytes() {
        let key = LegendCrypto.deriveWrapKey(code: Data(repeating: 7, count: 16))
        #expect(key.count == 32)
    }

    @Test func openRoundTripsSelfSealedData() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let aad = Data("42".utf8)
        let plaintext = Data(#"{"cost":3,"description":"Родник"}"#.utf8)
        let blob = seal(key: key, plaintext: plaintext, aad: aad)

        let out = try LegendCrypto.open(key: key, ivB64: blob.iv, ctB64: blob.ct, aad: aad)
        #expect(out == plaintext)
    }

    @Test func unlockRevealsCheckpointsThroughBundleIndirection() {
        let code = Data((0..<16).map { UInt8(($0 * 3) & 0xFF) })
        let wrapKey = LegendCrypto.deriveWrapKey(code: code)
        let bidBytes = Data(LegendCrypto.bid(code: code).utf8)

        // Per-CP content-ключ + его запечатанный plaintext (aad = десятичный id КП).
        let contentKey = Data((0..<32).map { UInt8(($0 + 1) & 0xFF) })
        let cpId = 103
        let enc = seal(
            key: contentKey,
            plaintext: Data(#"{"cost":5,"description":"Вершина"}"#.utf8),
            aad: Data(String(cpId).utf8)
        )

        // bundle_blob: { "<cpId>": "<b64 content_key>" }, запечатан wrap-ключом (aad = bid).
        let bundleJson = #"{"\#(cpId)":"\#(contentKey.base64EncodedString())"}"#
        let bundle = seal(key: wrapKey, plaintext: Data(bundleJson.utf8), aad: bidBytes)

        let tag = UnlockTag(checkpointId: cpId, iv: bundle.iv, ct: bundle.ct)
        let result = LegendCrypto.unlock(code: code, tag: tag, encById: [cpId: enc])

        guard case let .revealed(checkpointId, checkpoints) = result else {
            Issue.record("expected .revealed, got \(result)")
            return
        }
        #expect(checkpointId == cpId)
        #expect(checkpoints.count == 1)
        #expect(checkpoints.first == RevealedCheckpoint(id: cpId, cost: 5, description: "Вершина"))
    }

    @Test func unlockIdentityOnlyForOpenCpTag() {
        let result = LegendCrypto.unlock(
            code: Data(count: 16),
            tag: UnlockTag(checkpointId: 101, iv: nil, ct: nil),
            encById: [:]
        )
        #expect(result == .identityOnly(checkpointId: 101))
    }

    @Test func unlockFailsOnPartialEnvelope() {
        let tag = UnlockTag(checkpointId: 101, iv: "someIv", ct: nil)
        let result = LegendCrypto.unlock(code: Data(count: 16), tag: tag, encById: [:])
        guard case .failed = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
    }

    @Test func unlockFailsOnTamperedCiphertext() {
        let code = Data(repeating: 9, count: 16)
        let wrapKey = LegendCrypto.deriveWrapKey(code: code)
        let bidBytes = Data(LegendCrypto.bid(code: code).utf8)
        let bundle = seal(key: wrapKey, plaintext: Data(#"{"103":"AAAA"}"#.utf8), aad: bidBytes)

        // Флип первого Base64-символа ct (остаётся валидным Base64) → провал GCM-тега.
        let first = bundle.ct.first!
        let tamperedCt = (first == "A" ? "B" : "A") + bundle.ct.dropFirst()
        let tag = UnlockTag(checkpointId: 103, iv: bundle.iv, ct: tamperedCt)

        let result = LegendCrypto.unlock(code: code, tag: tag, encById: [:])
        guard case .failed = result else {
            Issue.record("expected .failed, got \(result)")
            return
        }
    }
}
