//
//  JudgeScanDtoTests.swift
//  kolco24Tests
//
//  Зеркало `data/api/dto/JudgeScanDtoTest.kt` — маппинг `JudgeScan → JudgeScanDto`, явный JSON
//  `null` для `trusted_ms`/`boot_count` (nullable-правило этапа 6), snake_case-ключи в JSON и
//  парсинг `accepted`. Кодирование сверяется через `JSONSerialization` над реально сериализованными
//  байтами (аналог `Json.encodeToString` + `.contains(...)` Kotlin-теста).
//

import Foundation
import Testing
@testable import kolco24

struct JudgeScanDtoTests {

    private func scan(
        trustedTakenAt: Int64? = 1_718_900_000_123,
        bootCount: Int? = 7
    ) -> JudgeScan {
        JudgeScan(
            id: "scan-1",
            raceId: 8,
            eventType: "start",
            participantNumber: 101,
            nfcUid: "04A2B3C4D5E680",
            takenAt: 1_718_900_000_000,
            trustedTakenAt: trustedTakenAt,
            elapsedRealtimeAt: 9_876_543,
            bootCount: bootCount,
            sourceInstallId: "install-uuid"
        )
    }

    // MARK: - Маппинг полей (зеркало toDto_*)

    @Test func toDto_mapsAllFields() {
        // Зеркало `toDto_mapsAllFields`.
        let dto = JudgeScanDto(from: scan())

        #expect(dto.id == "scan-1")
        #expect(dto.eventType == "start")
        #expect(dto.participantNumber == 101)
        #expect(dto.nfcUid == "04A2B3C4D5E680")
        #expect(dto.wallMs == 1_718_900_000_000)
        #expect(dto.trustedMs == 1_718_900_000_123)
        #expect(dto.elapsedAt == 9_876_543)
        #expect(dto.bootCount == 7)
    }

    @Test func toDto_nullTrustedTakenAt_mapsToNullTrustedMs() {
        // Зеркало `toDto_nullTrustedTakenAt_mapsToNullTrustedMs`.
        let dto = JudgeScanDto(from: scan(trustedTakenAt: nil))
        #expect(dto.trustedMs == nil)
        // wall_ms всегда присутствует (fallback, когда trusted_ms == nil).
        #expect(dto.wallMs == 1_718_900_000_000)
    }

    @Test func toDto_nullBootCount_mapsToNullBootCount() {
        // Зеркало `toDto_nullBootCount_mapsToNullBootCount`.
        let dto = JudgeScanDto(from: scan(bootCount: nil))
        #expect(dto.bootCount == nil)
    }

    // MARK: - Сериализация

    @Test func serialization_emitsSnakeCaseKeys() throws {
        // Зеркало `serialization_emitsSnakeCaseKeys`.
        let request = JudgeScanUploadRequest(
            sourceInstallId: "install-uuid",
            scans: [JudgeScanDto(from: scan())]
        )
        let encoded = String(data: try JSONEncoder().encode(request), encoding: .utf8)!

        #expect(encoded.contains("\"source_install_id\""))
        #expect(encoded.contains("\"event_type\""))
        #expect(encoded.contains("\"participant_number\""))
        #expect(encoded.contains("\"nfc_uid\""))
        #expect(encoded.contains("\"wall_ms\""))
        #expect(encoded.contains("\"trusted_ms\""))
        #expect(encoded.contains("\"elapsed_at\""))
        #expect(encoded.contains("\"boot_count\""))
        // Тела **без** `team_id` (судейский контракт — только raceId в URL).
        #expect(!encoded.contains("\"team_id\""))
    }

    @Test func serialization_nullTrustedMs_isExplicitJsonNull() throws {
        // Зеркало `serialization_nullTrustedMs_roundTrips` — но проверяем ЯВНЫЙ null (nullable-правило
        // этапа 6): ключ `trusted_ms` присутствует со значением JSON null, а не опущен.
        let dto = JudgeScanDto(from: scan(trustedTakenAt: nil, bootCount: nil))
        let data = try JSONEncoder().encode(dto)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(obj.keys.contains("trusted_ms"))
        #expect(obj["trusted_ms"] is NSNull)
        #expect(obj.keys.contains("boot_count"))
        #expect(obj["boot_count"] is NSNull)
        // Не-nullable поля — реальные значения.
        #expect((obj["wall_ms"] as? NSNumber)?.int64Value == 1_718_900_000_000)
        #expect((obj["elapsed_at"] as? NSNumber)?.int64Value == 9_876_543)
    }

    // MARK: - Десериализация ответа

    @Test func deserialization_parsesResponseAccepted() throws {
        // Зеркало `deserialization_parsesResponseAccepted`.
        let payload = Data(#"{"accepted": ["scan-1", "scan-2"]}"#.utf8)
        let response = try JSONDecoder().decode(JudgeScanUploadResponse.self, from: payload)
        #expect(response.accepted == ["scan-1", "scan-2"])
    }
}
