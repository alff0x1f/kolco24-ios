//
//  TrackUploadTests.swift
//  kolco24Tests
//
//  Зеркало `data/track/TrackUploadTest.kt` — маппер `TrackPoint → TrackPointDto` + эндпоинт
//  `uploadTrack` через `FakeTransport`. Имена кейсов 1:1 где применимо; плюс свежие проверки
//  JSON-формы (точные snake_case-ключи, явные `null` у no-default nullable, отсутствие локальных
//  полей `wall_ms`/`raceId`/`teamId`/флагов и `source_install_id`) — покрытие nullable-кодирования.
//

import Foundation
import Testing
@testable import kolco24

struct TrackUploadTests {

    // MARK: - Фикстуры

    /// Мирроринг `TrackUploadTest.entity(...)`: одна точка трека с настраиваемыми nullable-полями.
    private func point(
        id: String,
        trustedMs: Int64? = 1_718_900_000_123,
        bootCount: Int? = 7,
        altitude: Double? = 187.5,
        verticalAccuracyMeters: Float? = 3.2
    ) -> TrackPoint {
        TrackPoint(
            id: id,
            raceId: 8,
            teamId: 42,
            lat: 55.75,
            lon: 37.61,
            accuracy: 12.4,
            altitude: altitude,
            verticalAccuracyMeters: verticalAccuracyMeters,
            gpsTimeMs: 1_718_900_000_000,
            elapsedRealtimeAt: 9_876_543,
            bootCount: bootCount,
            wallMs: 1_718_900_000_000,
            trustedMs: trustedMs,
            segmentId: "seg-1",
            uploadedLocal: false,
            uploadedCloud: false
        )
    }

    /// Кодирует DTO и разбирает обратно в `[String: Any]` (NSNull для JSON null) — снапшот формы.
    private func encodedDict(_ dto: TrackPointDto) throws -> [String: Any] {
        let data = try JSONEncoder().encode(dto)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func makeClient(_ transport: FakeTransport) -> ApiClient {
        ApiClient(
            baseURL: "https://example.test",
            keyId: "ios-v1",
            secret: "test-secret-123",
            installId: "install-abc",
            appVersion: "2.0.1",
            nowSeconds: { 1_718_200_000 },
            elapsedNowMs: { 0 },
            transport: transport.handle
        )
    }

    // MARK: - Маппер toDto (зеркало TrackUploadTest)

    @Test func toDto_mapsFixMomentFieldsAndDropsLocalOnly() {
        let dto = TrackPointDto(from: point(id: "uuid-1"))

        #expect(dto.id == "uuid-1")
        #expect(dto.segmentId == "seg-1")
        #expect(dto.lat == 55.75)
        #expect(dto.lon == 37.61)
        #expect(dto.accuracy == 12.4)
        #expect(dto.altitude == 187.5)
        #expect(dto.verticalAccuracyMeters == 3.2)
        #expect(dto.gpsTimeMs == 1_718_900_000_000)
        #expect(dto.trustedMs == 1_718_900_000_123)
        // elapsed_at ← elapsedRealtimeAt (не gpsTimeMs).
        #expect(dto.elapsedAt == 9_876_543)
        #expect(dto.bootCount == 7)
    }

    @Test func toDto_carriesSegmentId_andSerializesAsSegmentIdJson() throws {
        let dto = TrackPointDto(from: point(id: "uuid-seg"))
        #expect(dto.segmentId == "seg-1")

        let json = try encodedDict(dto)
        #expect(json["segment_id"] as? String == "seg-1")
    }

    @Test func toDto_nullTrustedAndBoot_serializeAsJsonNull() throws {
        let dto = TrackPointDto(from: point(id: "uuid-2", trustedMs: nil, bootCount: nil))
        let json = try encodedDict(dto)

        #expect(json.keys.contains("trusted_ms"))
        #expect(json["trusted_ms"] is NSNull)
        #expect(json.keys.contains("boot_count"))
        #expect(json["boot_count"] is NSNull)
    }

    @Test func toDto_nullAltitude_serializeAsJsonNull() throws {
        let dto = TrackPointDto(from: point(id: "uuid-3", altitude: nil, verticalAccuracyMeters: nil))
        let json = try encodedDict(dto)

        #expect(json.keys.contains("altitude"))
        #expect(json["altitude"] is NSNull)
        #expect(json.keys.contains("vertical_accuracy"))
        #expect(json["vertical_accuracy"] is NSNull)
    }

    @Test func json_usesExactSnakeCaseKeys_andOmitsLocalOnlyFields() throws {
        let dto = TrackPointDto(from: point(id: "uuid-keys"))
        let json = try encodedDict(dto)

        // snake_case-ключи
        #expect(json["segment_id"] as? String == "seg-1")
        #expect(json["vertical_accuracy"] as? Double == 3.2)
        #expect(json["gps_time_ms"] as? Int64 == 1_718_900_000_000)
        #expect(json["trusted_ms"] as? Int64 == 1_718_900_000_123)
        #expect(json["elapsed_at"] as? Int64 == 9_876_543)
        #expect(json["boot_count"] as? Int == 7)

        // локальные поля НЕ уходят на провод
        #expect(!json.keys.contains("wall_ms"))
        #expect(!json.keys.contains("wallMs"))
        #expect(!json.keys.contains("raceId"))
        #expect(!json.keys.contains("teamId"))
        #expect(!json.keys.contains("uploadedLocal"))
        #expect(!json.keys.contains("uploadedCloud"))
    }

    // MARK: - Эндпоинт (зеркало TrackUploadTest, через FakeTransport)

    // Примечание: Kotlin-кейсы `localInstance_uploadTrack_*` (отдельный LAN-клиент 200/403/offline) здесь
    // сознательно НЕ дублируются — `uploadTrack` подписывает/шлёт идентично для любого `baseURL` (общий
    // generic-`post`, без `onServerTime`-специфики у трека), а реальный LAN-путь (клиент `makeLocal`)
    // прогоняется в `TrackUploadRepositoryTests` (Local-цикл `flushScope`). Достаточно одного набора кейсов.

    @Test func uploadTrack_200_returnsAcceptedIds_andPostsBatchToTrackUrl() async throws {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, bodyString: #"{"accepted":["a","b"]}"#)
        let client = makeClient(transport)

        let points = [TrackPointDto(from: point(id: "a")), TrackPointDto(from: point(id: "b"))]
        let result = await client.uploadTrack(raceId: 8, teamId: 42, points: points)

        guard case .success(let response) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(response.accepted == ["a", "b"])

        let recorded = try #require(transport.last)
        #expect(recorded.httpMethod == "POST")
        // Полный URL со слэшем — он входит в подписанную канонику (URL.path срезает хвост).
        #expect(recorded.url?.absoluteString == "https://example.test/app/race/8/track/")

        let body = try #require(recorded.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["team_id"] as? Int == 42)
        // source_install_id НЕ шлётся (расхождение с UPLOAD.md — зеркало Kotlin-клиента).
        #expect(!json.keys.contains("source_install_id"))
        let wire = try #require(json["points"] as? [[String: Any]])
        #expect(wire.first?["segment_id"] as? String == "seg-1")
    }

    @Test func uploadTrack_emptyBatch_postsEmptyPointsList() async throws {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, bodyString: #"{"accepted":[]}"#)
        let client = makeClient(transport)

        let result = await client.uploadTrack(raceId: 8, teamId: 42, points: [])

        guard case .success(let response) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(response.accepted.isEmpty)

        let body = try #require(transport.last?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["team_id"] as? Int == 42)
        #expect((json["points"] as? [[String: Any]])?.isEmpty == true)
        #expect(!json.keys.contains("source_install_id"))
    }

    @Test func uploadTrack_201_returnsAcceptedIds() async {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 201, bodyString: #"{"accepted":["a"]}"#)
        let result = await makeClient(transport).uploadTrack(
            raceId: 8, teamId: 42, points: [TrackPointDto(from: point(id: "a"))]
        )
        guard case .success(let response) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(response.accepted == ["a"])
    }

    @Test func uploadTrack_403_returnsForbidden_singleRequest() async {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 403)
        let result = await makeClient(transport).uploadTrack(raceId: 8, teamId: 42, points: [])
        if case .forbidden = result {} else { Issue.record("ожидался .forbidden, получено \(result)") }
        // POST не ретраится — ровно один запрос.
        #expect(transport.callCount == 1)
    }

    @Test func uploadTrack_401_returnsUnauthorized() async {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 401)
        let result = await makeClient(transport).uploadTrack(raceId: 8, teamId: 42, points: [])
        if case .unauthorized = result {} else { Issue.record("ожидался .unauthorized, получено \(result)") }
    }

    @Test func uploadTrack_400_returnsBadRequest() async {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 400)
        let result = await makeClient(transport).uploadTrack(raceId: 8, teamId: 42, points: [])
        if case .badRequest = result {} else { Issue.record("ожидался .badRequest, получено \(result)") }
    }

    @Test func uploadTrack_429_returnsRateLimited() async {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 429)
        let result = await makeClient(transport).uploadTrack(raceId: 8, teamId: 42, points: [])
        if case .rateLimited = result {} else { Issue.record("ожидался .rateLimited, получено \(result)") }
    }

    @Test func uploadTrack_offline_returnsOffline() async {
        let transport = FakeTransport()
        transport.enqueueError(URLError(.notConnectedToInternet))
        let result = await makeClient(transport).uploadTrack(raceId: 8, teamId: 42, points: [])
        if case .offline = result {} else { Issue.record("ожидался .offline, получено \(result)") }
    }
}
