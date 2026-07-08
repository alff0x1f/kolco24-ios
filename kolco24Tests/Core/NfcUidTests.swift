//
//  NfcUidTests.swift
//  kolco24Tests
//
//  Зеркало `data/NfcUidTest.kt` (4 кейса) 1:1. Заодно покрывают hex-хелперы
//  (`HexBytes.encode` в верхнем регистре, знаковые байты).
//

import Foundation
import Testing
@testable import kolco24

struct NfcUidTests {

    @Test func singleLeadingZeroByte_zeroPaddedUppercaseHex() {
        #expect(normalizeNfcUid(Data([0x04])) == "04")
    }

    @Test func multiByteUid_concatenatedUppercaseHex() {
        let bytes = Data([0x04, 0xA2, 0xB3, 0xC4, 0xD5, 0xE6, 0x80])
        #expect(normalizeNfcUid(bytes) == "04A2B3C4D5E680")
    }

    @Test func fullByteRange_handlesSignedBytes() {
        #expect(normalizeNfcUid(Data([0x00, 0xFF, 0x7F, 0x80])) == "00FF7F80")
    }

    @Test func emptyArray_emptyString() {
        #expect(normalizeNfcUid(Data()) == "")
    }
}
