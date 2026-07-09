//
//  MarkMemberSnapshotListCodecTests.swift
//  kolco24Tests
//
//  Зеркало Android `MarkMemberSnapshotListConverterTest` (JVM). Проверяет кодек
//  JSON-колонки `marks.presentDetails` (`MarkPresentDetailsCodec`, порт
//  `MarkMemberSnapshotListConverter`): round-trip, пустой список → `"[]"`,
//  NULL ↔ nil, битый JSON → nil, незнакомые ключи игнорируются (forward-compat).
//

import Testing
@testable import kolco24

struct MarkMemberSnapshotListCodecTests {

    @Test func roundTripPreservesValuesAndOrder() {
        let values = [
            MarkMemberSnapshot(numberInTeam: 2, nfcUid: "04AABBCC", number: 17, code: "deadbeef"),
            MarkMemberSnapshot(numberInTeam: 1, nfcUid: nil, number: 3, code: nil),
        ]
        let restored = MarkPresentDetailsCodec.decode(MarkPresentDetailsCodec.encode(values))
        #expect(restored == values)
    }

    @Test func roundTripEmptyList() {
        let restored = MarkPresentDetailsCodec.decode(MarkPresentDetailsCodec.encode([]))
        #expect(restored != nil)
        #expect(restored?.isEmpty == true)
    }

    @Test func emptyListSerializesToJsonArray() {
        #expect(MarkPresentDetailsCodec.encode([]) == "[]")
    }

    @Test func nullRoundTripsToNull() {
        #expect(MarkPresentDetailsCodec.encode(nil) == nil)
        #expect(MarkPresentDetailsCodec.decode(nil) == nil)
    }

    @Test func malformedInputReturnsNull() {
        #expect(MarkPresentDetailsCodec.decode("not-json") == nil)
        #expect(MarkPresentDetailsCodec.decode("{\"key\":\"value\"}") == nil)
    }

    @Test func unknownFieldsIgnoredForwardCompat() {
        // Проверяет, что незнакомые ключи игнорируются (аналог kotlinx
        // ignoreUnknownKeys = true): будущий формат с новыми полями не должен
        // ломать декодирование и терять весь список снапшотов.
        let json = #"[{"numberInTeam":1,"nfcUid":null,"number":3,"code":null,"futureField":"x"}]"#
        let result = MarkPresentDetailsCodec.decode(json)
        #expect(result?.count == 1)
        #expect(result?[0].numberInTeam == 1)
        #expect(result?[0].number == 3)
    }
}
