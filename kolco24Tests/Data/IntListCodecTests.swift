//
//  IntListCodecTests.swift
//  kolco24Tests
//
//  Зеркало Android `IntListConverterTest` (JVM). Проверяет кодек JSON-колонки
//  `marks.present` (`MarkPresentCodec`, порт `IntListConverter`): round-trip
//  сохраняет значения/порядок/дубликаты, битый JSON → пустой список без краша.
//

import Testing
@testable import kolco24

struct IntListCodecTests {

    @Test func roundTripPreservesValuesAndOrder() {
        let values = [3, 1, 2]
        let restored = MarkPresentCodec.decode(MarkPresentCodec.encode(values))
        #expect(restored == values)
    }

    @Test func roundTripEmptyList() {
        let restored = MarkPresentCodec.decode(MarkPresentCodec.encode([]))
        #expect(restored.isEmpty)
    }

    @Test func roundTripPreservesDuplicates() {
        let values = [1, 1, 2, 2, 2]
        let restored = MarkPresentCodec.decode(MarkPresentCodec.encode(values))
        #expect(restored == values)
    }

    @Test func malformedInputReturnsEmptyList() {
        #expect(MarkPresentCodec.decode("not-json").isEmpty)
        #expect(MarkPresentCodec.decode("{\"key\":\"value\"}").isEmpty)
    }
}
