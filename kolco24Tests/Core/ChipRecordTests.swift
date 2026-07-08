//
//  ChipRecordTests.swift
//  kolco24Tests
//
//  Зеркало `data/nfc/MifareUltralightWriterTest.kt` (39 кейсов) 1:1: hex-кодек,
//  сборка/разбор сырой записи, распознавание модели, и командная логика
//  write/read через фейковый `NfcTransport` (порядок записи страниц, обрыв,
//  read-back mismatch).
//

import Foundation
import Testing
@testable import kolco24

struct ChipRecordTests {

    private let sampleCode = Data([
        0x04, 0xA2, 0xB3, 0xC4,
        0xD5, 0xE6, 0x80, 0x01,
        0x7F, 0x00, 0xFF, 0x55, 0xAA, 0x12, 0x34, 0x56,
    ])

    // --- chipCodeHex / chipCodeFromHex --------------------------------------

    @Test func chipCodeHex_knownVector_zeroAndFF() {
        #expect(chipCodeHex(Data([0x00, 0xFF])) == "00FF")
    }

    @Test func chipCodeHex_signedBytesHandled() {
        #expect(chipCodeHex(Data([0x80, 0x81, 0x7F, 0x00])) == "80817F00")
    }

    @Test func chipCodeHex_outputIsUppercase() {
        #expect(chipCodeHex(Data([0xAB, 0xCD, 0xEF])) == "ABCDEF")
    }

    @Test func chipCodeFromHex_knownVector() throws {
        #expect(try chipCodeFromHex("00FF") == Data([0x00, 0xFF]))
    }

    @Test func chipCodeFromHex_roundTripWithChipCodeHex() throws {
        let original = Data([
            0x04, 0xA2, 0xB3, 0xC4,
            0xD5, 0xE6, 0x80, 0x01,
            0x7F, 0x00, 0xFF, 0x55, 0xAA, 0x12, 0x34, 0x56,
        ])
        #expect(try chipCodeFromHex(chipCodeHex(original)) == original)
    }

    // Kotlin `chipCodeFromHex` бросает `IllegalArgumentException` (require + digitToInt(16)),
    // а не роняет процесс: провижининг ловит и показывает «Неверный код от сервера».
    @Test func chipCodeFromHex_oddLength_throws() {
        #expect(throws: ChipRecordError.invalidHex) {
            try chipCodeFromHex("0FF")
        }
    }

    @Test func chipCodeFromHex_nonHexCharacter_throws() {
        #expect(throws: ChipRecordError.invalidHex) {
            try chipCodeFromHex("00GZ")
        }
    }

    // --- Raw chip record format ---------------------------------------------

    @Test func buildChipRecord_length_is20() throws {
        #expect(try buildChipRecord(type: CHIP_TYPE_KP, code: sampleCode).count == 20)
    }

    @Test func buildChipRecord_byteVector_magicPackedCode() throws {
        let record = try buildChipRecord(type: CHIP_TYPE_KP, code: sampleCode)
        let expected = Data([0x4B, 0x32, 0x34, 0x11]) + sampleCode
        #expect(record == expected)
    }

    @Test func buildChipRecord_packedByte_isVersion1TypeKp() throws {
        let record = try buildChipRecord(type: CHIP_TYPE_KP, code: sampleCode)
        #expect(record[3] == 0x11)
    }

    @Test func buildChipRecord_wrongSizeCode_throws() {
        #expect(throws: ChipRecordError.self) {
            try buildChipRecord(type: CHIP_TYPE_KP, code: Data([0x00, 0x01]))
        }
    }

    @Test func buildChipRecord_typeOutOfNibbleRange_throws() {
        #expect(throws: ChipRecordError.self) {
            try buildChipRecord(type: 16, code: sampleCode)
        }
    }

    @Test func parseChipRecord_validKp_returnsCode() throws {
        let record = try buildChipRecord(type: CHIP_TYPE_KP, code: sampleCode)
        #expect(parseChipRecord(pages: record) == sampleCode)
    }

    @Test func parseChipRecord_wrongMagicFirstByte_returnsNull() throws {
        var record = try buildChipRecord(type: CHIP_TYPE_KP, code: sampleCode)
        record[0] = 0x00
        #expect(parseChipRecord(pages: record) == nil)
    }

    @Test func parseChipRecord_wrongMagicSecondByte_returnsNull() throws {
        var record = try buildChipRecord(type: CHIP_TYPE_KP, code: sampleCode)
        record[1] = 0x00
        #expect(parseChipRecord(pages: record) == nil)
    }

    @Test func parseChipRecord_wrongMagicThirdByte_returnsNull() throws {
        var record = try buildChipRecord(type: CHIP_TYPE_KP, code: sampleCode)
        record[2] = 0x35
        #expect(parseChipRecord(pages: record) == nil)
    }

    @Test func parseChipRecord_allZero_returnsNull() {
        #expect(parseChipRecord(pages: Data(count: 20)) == nil)
    }

    @Test func parseChipRecord_tooShort_returnsNull() {
        #expect(parseChipRecord(pages: Data(count: 19)) == nil)
    }

    @Test func parseChipRecord_participantType_returnsNull() {
        // version 1, type 2 (participant) → packed 0x12
        let record = Data([0x4B, 0x32, 0x34, 0x12]) + sampleCode
        #expect(parseChipRecord(pages: record) == nil)
    }

    @Test func parseChipRecord_unknownVersion_returnsNull() {
        // version 2, type 1 (КП) → packed 0x21
        let record = Data([0x4B, 0x32, 0x34, 0x21]) + sampleCode
        #expect(parseChipRecord(pages: record) == nil)
    }

    @Test func parseChipRecord_trailingPadding_tolerated() throws {
        let record = try buildChipRecord(type: CHIP_TYPE_KP, code: sampleCode) + Data(count: 8)
        #expect(parseChipRecord(pages: record) == sampleCode)
    }

    @Test func parseChipRecord_roundTripWithBuildChipRecord() throws {
        #expect(parseChipRecord(pages: try buildChipRecord(type: CHIP_TYPE_KP, code: sampleCode)) == sampleCode)
    }

    // --- GET_VERSION model parsing ------------------------------------------

    @Test func chipModelFromVersion_ntag213Vector() {
        let resp = Data([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x0F, 0x03])
        #expect(chipModelFromVersion(resp) == "NTAG213")
    }

    @Test func chipModelFromVersion_ntag215Vector() {
        let resp = Data([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x11, 0x03])
        #expect(chipModelFromVersion(resp) == "NTAG215")
    }

    @Test func chipModelFromVersion_ntag216Vector() {
        let resp = Data([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x13, 0x03])
        #expect(chipModelFromVersion(resp) == "NTAG216")
    }

    @Test func chipModelFromVersion_ultralightProductByte() {
        let resp = Data([0x00, 0x04, 0x03, 0x01, 0x01, 0x00, 0x0B, 0x03])
        #expect(chipModelFromVersion(resp) == "MIFARE Ultralight")
    }

    @Test func chipModelFromVersion_unknownNtagStorage() {
        let resp = Data([0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x7F, 0x03])
        #expect(chipModelFromVersion(resp) == "NTAG (неизвестно)")
    }

    @Test func chipModelFromVersion_unknownProductType() {
        let resp = Data([0x00, 0x04, 0x99, 0x02, 0x01, 0x00, 0x0F, 0x03])
        #expect(chipModelFromVersion(resp) == "неизвестно")
    }

    @Test func chipModelFromVersion_emptyResponse_returnsUnknown() {
        #expect(chipModelFromVersion(Data()) == "неизвестно")
    }

    @Test func chipModelFromVersion_shortResponse_returnsUnknown() {
        #expect(chipModelFromVersion(Data([0x00, 0x04, 0x04])) == "неизвестно")
    }

    // --- Transport-driven write/read sequencing (fake NfcTransport) ----------

    /// Ошибка, имитирующая обрыв I/O (аналог `IOException` в Kotlin-тесте).
    private struct FakeIOError: Error {}

    /// Пишет каждый отправленный кадр и отвечает через [responder] (может бросить, имитируя I/O).
    private final class FakeTransport: NfcTransport {
        let responder: (Data) throws -> Data
        var frames: [Data] = []

        init(_ responder: @escaping (Data) throws -> Data) {
            self.responder = responder
        }

        func transceive(_ frame: Data) throws -> Data {
            frames.append(frame)
            return try responder(frame)
        }
    }

    private let WRITE: UInt8 = 0xA2
    private let ACK = Data([0x0A])
    private let NAK = Data([0x00])
    private let FAST_READ: UInt8 = 0x3A
    private let READ: UInt8 = 0x30

    @Test func writeRecord_writesHeaderLast_andSucceeds() throws {
        let record = try buildChipRecord(type: CHIP_TYPE_KP, code: sampleCode)
        let t = FakeTransport { frame in
            switch frame[0] {
            case self.WRITE: return self.ACK
            case self.FAST_READ: return record // read-back sees the valid record
            default: return self.NAK
            }
        }
        #expect(writeRecord(t, record: record) == .success)

        let writes = t.frames.filter { $0[0] == WRITE }
        #expect(writes.count == 6) // page-4 invalidate + 4 code pages + page-4 header
        // first write invalidates page 4 with an all-zero header
        #expect(writes[0][1] == 4)
        #expect(Data([UInt8](writes[0])[2..<6]) == Data([0, 0, 0, 0]))
        // code pages 5..8 are written in between, with correct payload bytes
        #expect(writes[1..<5].map { Int([UInt8]($0)[1]) } == [5, 6, 7, 8])
        for i in 0..<4 {
            let payload = Data([UInt8](writes[1 + i])[2..<6])
            let expected = Data([UInt8](record)[(4 + i * 4)..<(8 + i * 4)])
            #expect(payload == expected, "code page \(5 + i) payload")
        }
        // the valid header is committed to page 4 last
        let last = writes[writes.count - 1]
        #expect(last[1] == 4)
        #expect(Data([UInt8](last)[2..<6]) == Data([0x4B, 0x32, 0x34, 0x11]))
    }

    @Test func writeRecord_nakOnWrite_failsWithNoFurtherFrames() throws {
        let record = try buildChipRecord(type: CHIP_TYPE_KP, code: sampleCode)
        let t = FakeTransport { _ in self.NAK } // NAK every frame
        #expect(isFailed(writeRecord(t, record: record)))
        #expect(t.frames.count == 1) // stopped after the first (invalidate) WRITE
    }

    @Test func writeRecord_nakOnCodePage_returnsFailed() throws {
        // Invalidate (page 4) ACKs, but the first code page (page 5) NAKs → Failed, stops early.
        let record = try buildChipRecord(type: CHIP_TYPE_KP, code: sampleCode)
        var writeCount = 0
        let t = FakeTransport { frame in
            if frame[0] == self.WRITE {
                writeCount += 1
                return writeCount == 1 ? self.ACK : self.NAK // ACK invalidate, NAK code page 5
            }
            return self.NAK
        }
        #expect(isFailed(writeRecord(t, record: record)))
        // Only 2 WRITEs: the invalidate + the first code page (which NAKed).
        let writes = t.frames.filter { $0[0] == WRITE }
        #expect(writes.count == 2)
    }

    @Test func writeRecord_ioExceptionOnWrite_returnsFailed() throws {
        let record = try buildChipRecord(type: CHIP_TYPE_KP, code: sampleCode)
        let t = FakeTransport { frame in
            if frame[0] == self.WRITE { throw FakeIOError() }
            return self.NAK
        }
        #expect(isFailed(writeRecord(t, record: record)))
    }

    @Test func writeRecord_readBackMismatch_returnsFailed() throws {
        let record = try buildChipRecord(type: CHIP_TYPE_KP, code: sampleCode)
        let t = FakeTransport { frame in
            switch frame[0] {
            case self.WRITE: return self.ACK
            case self.FAST_READ: return Data(count: 20) // all-zero → parses null → mismatch
            default: return self.NAK
            }
        }
        #expect(isFailed(writeRecord(t, record: record)))
    }

    @Test func readRecord_fastReadHappyPath_returnsCode() throws {
        let record = try buildChipRecord(type: CHIP_TYPE_KP, code: sampleCode)
        let t = FakeTransport { frame in frame[0] == self.FAST_READ ? record : self.NAK }
        #expect(readRecord(t) == sampleCode)
    }

    /// Page-4 READ → record bytes 0..15; page-8 READ → bytes 16..19 (+ padding).
    private func fallbackRead(_ record: Data, _ frame: Data) -> Data {
        switch frame[1] {
        case 4: return Data([UInt8](record)[0..<16])
        case 8: return Data([UInt8](record)[16..<20]) + Data(count: 12)
        default: return NAK
        }
    }

    @Test func readRecord_fastReadThrows_fallsBackToReads() throws {
        let record = try buildChipRecord(type: CHIP_TYPE_KP, code: sampleCode)
        let t = FakeTransport { frame in
            switch frame[0] {
            case self.FAST_READ: throw FakeIOError()
            case self.READ: return self.fallbackRead(record, frame)
            default: return self.NAK
            }
        }
        #expect(readRecord(t) == sampleCode)
    }

    @Test func readRecord_fastReadNak_fallsBackToReads() throws {
        let record = try buildChipRecord(type: CHIP_TYPE_KP, code: sampleCode)
        let t = FakeTransport { frame in
            switch frame[0] {
            case self.FAST_READ: return self.NAK // 1-byte NAK, shorter than 20 bytes
            case self.READ: return self.fallbackRead(record, frame)
            default: return self.NAK
            }
        }
        #expect(readRecord(t) == sampleCode)
    }

    @Test func readRecord_shortSecondRead_returnsNull() throws {
        let record = try buildChipRecord(type: CHIP_TYPE_KP, code: sampleCode)
        let t = FakeTransport { frame in
            if frame[0] == self.FAST_READ { return self.NAK }
            if frame[0] == self.READ && frame[1] == 4 { return Data([UInt8](record)[0..<16]) }
            if frame[0] == self.READ && frame[1] == 8 { return self.NAK } // short second READ
            return self.NAK
        }
        #expect(readRecord(t) == nil)
    }

    @Test func readRecord_ioExceptionOnFirstRead_returnsNull() {
        let t = FakeTransport { frame in
            if frame[0] == self.FAST_READ { return self.NAK }
            if frame[0] == self.READ && frame[1] == 4 { throw FakeIOError() }
            return self.NAK
        }
        #expect(readRecord(t) == nil)
    }

    @Test func readRecord_ioExceptionOnSecondRead_returnsNull() throws {
        let record = try buildChipRecord(type: CHIP_TYPE_KP, code: sampleCode)
        let t = FakeTransport { frame in
            if frame[0] == self.FAST_READ { return self.NAK }
            if frame[0] == self.READ && frame[1] == 4 { return Data([UInt8](record)[0..<16]) }
            if frame[0] == self.READ && frame[1] == 8 { throw FakeIOError() }
            return self.NAK
        }
        #expect(readRecord(t) == nil)
    }

    /// Аналог Kotlin `result is ChipWriteResult.Failed` — сообщение не проверяется.
    private func isFailed(_ result: ChipWriteResult) -> Bool {
        if case .failed = result { return true }
        return false
    }
}
