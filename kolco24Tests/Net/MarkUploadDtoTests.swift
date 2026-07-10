//
//  MarkUploadDtoTests.swift
//  kolco24Tests
//
//  Зеркало `data/api/dto/MarkDtoMappingTest.kt` (merge `present[]` + маппинг полей) и
//  `data/api/ApiClientMarksTest.kt` (эндпоинт `uploadMarks`) — имена кейсов 1:1 где применимо.
//  Плюс свежие проверки JSON-формы (точные snake_case-ключи, явные `null` у no-default скаляров,
//  отсутствие ключа `location` при nil-фиксе) — покрытие nullable-кодирования (Technical Details).
//

import Foundation
import Testing
@testable import kolco24

struct MarkUploadDtoTests {

    // MARK: - Фикстуры

    /// Мирроринг `MarkDtoMappingTest.mark(...)`: одно взятие с настраиваемыми `present`/снимками/GPS.
    private func mark(
        present: [Int] = [],
        presentDetails: [MarkMemberSnapshot]? = nil,
        locLat: Double? = nil,
        locLon: Double? = nil,
        method: String = "nfc",
        cpUid: String = "04A2B3C4D5E680",
        cpCode: String = "9f1a2b3c4d5e6f70",
        trustedTakenAt: Int64? = 1_718_900_000_123,
        elapsedRealtimeAt: Int64? = 9_876_543,
        bootCount: Int? = 7
    ) -> Mark {
        let hasFix = locLat != nil
        return Mark(
            id: "mark-1",
            raceId: 7,
            teamId: 42,
            checkpointId: 264,
            checkpointNumber: 12,
            cost: 5,
            method: method,
            cpUid: cpUid,
            cpCode: cpCode,
            present: present,
            presentDetails: presentDetails,
            expectedCount: 4,
            complete: true,
            takenAt: 1_718_900_000_000,
            updatedAt: 1_718_900_000_500,
            trustedTakenAt: trustedTakenAt,
            elapsedRealtimeAt: elapsedRealtimeAt,
            bootCount: bootCount,
            locLat: locLat,
            locLon: hasFix ? (locLon ?? 37.61) : locLon,
            locAccuracy: hasFix ? 12.4 : nil,
            locAltitude: hasFix ? 184.2 : nil,
            locVerticalAccuracy: hasFix ? 3.2 : nil,
            locGpsTimeMs: hasFix ? 1_718_900_000_001 : nil,
            locElapsedRealtimeAt: hasFix ? 9_870_000 : nil
        )
    }

    /// Кодирует DTO и разбирает обратно в `[String: Any]` (NSNull для JSON null) — снапшот формы.
    private func encodedDict(_ dto: MarkDto) throws -> [String: Any] {
        let data = try JSONEncoder().encode(dto)
        return try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    // MARK: - Merge present[] (зеркало MarkDtoMappingTest)

    @Test func fullSnapshot_buildsPresentWithUidAndNumber() throws {
        let dto = MarkDto(from: mark(
            present: [1, 2],
            presentDetails: [
                MarkMemberSnapshot(numberInTeam: 1, nfcUid: "04F1E2", number: 101, code: "c3d4"),
                MarkMemberSnapshot(numberInTeam: 2, nfcUid: "041122", number: 102, code: nil),
            ]
        ))

        #expect(dto.present.count == 2)
        // Порядок = порядок Mark.present
        #expect(dto.present.map(\.numberInTeam) == [1, 2])
        let m1 = try #require(dto.present.first { $0.numberInTeam == 1 })
        #expect(m1.nfcUid == "04F1E2")
        #expect(m1.code == "c3d4")
        #expect(m1.number == 101)
        let m2 = try #require(dto.present.first { $0.numberInTeam == 2 })
        #expect(m2.nfcUid == "041122")
        #expect(m2.code == nil)
        #expect(m2.number == 102)
    }

    @Test func location_nullWhenLatPresentButLonNull() {
        // locLat != nil но locLon == nil: null location, не 0.0 долгота.
        // Строим inline — фикстура `mark(...)` авто-заполняет locLon при наличии locLat.
        let m = Mark(
            id: "mark-1", raceId: 7, teamId: 42, checkpointId: 264, checkpointNumber: 12,
            cost: 5, method: "nfc", cpUid: "AA", cpCode: "bb",
            present: [1], presentDetails: nil, expectedCount: 4, complete: true,
            takenAt: 1, updatedAt: 1, locLat: 55.75, locLon: nil
        )
        #expect(MarkDto(from: m).location == nil)
    }

    @Test func nullPresentDetails_mergesAllPresentAsSentinels() {
        let dto = MarkDto(from: mark(present: [1, 2], presentDetails: nil))

        #expect(dto.present.count == 2)
        for m in dto.present {
            #expect(m.nfcUid == nil)
            #expect(m.code == nil)
            #expect(m.number == 0)
        }
        #expect(dto.present.map(\.numberInTeam) == [1, 2])
    }

    @Test func partialDetails_enrichesMatchedSlotsSentinelsTheRest() throws {
        let dto = MarkDto(from: mark(
            present: [1, 2, 3],
            presentDetails: [
                MarkMemberSnapshot(numberInTeam: 2, nfcUid: "0422", number: 202, code: nil),
            ]
        ))

        #expect(dto.present.count == 3)
        let m2 = try #require(dto.present.first { $0.numberInTeam == 2 })
        #expect(m2.nfcUid == "0422")
        #expect(m2.number == 202)
        for num in [1, 3] {
            let s = try #require(dto.present.first { $0.numberInTeam == num })
            #expect(s.nfcUid == nil)
            #expect(s.number == 0)
        }
    }

    @Test func location_nonNull_mapsAllSevenFields() throws {
        let dto = MarkDto(from: mark(present: [1], locLat: 55.75))
        let loc = try #require(dto.location)
        #expect(loc.lat == 55.75)
        #expect(loc.lon == 37.61)
        #expect(loc.accuracy == 12.4)
        #expect(loc.altitude == 184.2)
        #expect(loc.verticalAccuracy == 3.2)
        #expect(loc.gpsTimeMs == 1_718_900_000_001)
        #expect(loc.elapsedAt == 9_870_000)
    }

    @Test func location_nullWhenNoFix() {
        let dto = MarkDto(from: mark(present: [1], locLat: nil))
        #expect(dto.location == nil)
    }

    @Test func nullableTimes_passThrough() {
        let dto = MarkDto(from: mark(
            present: [1],
            trustedTakenAt: nil,
            elapsedRealtimeAt: nil,
            bootCount: nil
        ))
        #expect(dto.trustedMs == nil)
        #expect(dto.elapsedAt == nil)
        #expect(dto.bootCount == nil)
        // wall_ms всегда есть (единственный fallback, когда trusted_ms == nil).
        #expect(dto.wallMs == 1_718_900_000_000)
    }

    @Test func renamedFields_comeFromCorrectEntityColumns() {
        let dto = MarkDto(from: mark(present: [1]))
        #expect(dto.cpCode == "9f1a2b3c4d5e6f70")
        #expect(dto.cpNfcUid == "04A2B3C4D5E680")
        #expect(dto.wallMs == 1_718_900_000_000)
        #expect(dto.trustedMs == 1_718_900_000_123)
        #expect(dto.elapsedAt == 9_876_543)
        #expect(dto.checkpointId == 264)
        #expect(dto.method == "nfc")
        #expect(dto.expectedCount == 4)
        #expect(dto.complete == true)
    }

    @Test func emptyPresent_producesEmptyArray() {
        let dto = MarkDto(from: mark(present: []))
        #expect(dto.present.isEmpty)
    }

    @Test func photoMark_mapsMethodEmptyCpFieldsEmptyPresentComplete() {
        // Зеркало MarkRepository.createPhotoMark: method="photo", cpUid/cpCode="", present=[].
        let dto = MarkDto(from: mark(
            present: [],
            presentDetails: nil,
            method: "photo",
            cpUid: "",
            cpCode: ""
        ))
        #expect(dto.method == "photo")
        #expect(dto.cpCode == "")
        #expect(dto.cpNfcUid == "")
        #expect(dto.present.isEmpty)
        #expect(dto.complete == true)
        #expect(dto.wallMs == 1_718_900_000_000)
        #expect(dto.trustedMs == 1_718_900_000_123)
        #expect(dto.elapsedAt == 9_876_543)
    }

    @Test func photoMark_withLocation_mapsAntiCheatCoordinate() throws {
        let dto = MarkDto(from: mark(
            present: [],
            locLat: 55.75,
            method: "photo",
            cpUid: "",
            cpCode: ""
        ))
        #expect(dto.method == "photo")
        let loc = try #require(dto.location)
        #expect(loc.lat == 55.75)
        #expect(loc.lon == 37.61)
    }

    // MARK: - JSON-форма (точные ключи + явные null)

    @Test func json_usesExactSnakeCaseKeys() throws {
        let dto = MarkDto(from: mark(
            present: [1],
            presentDetails: [
                MarkMemberSnapshot(numberInTeam: 1, nfcUid: "04F1E2", number: 101, code: "c3d4"),
            ],
            locLat: 55.75
        ))
        let json = try encodedDict(dto)

        // Ловушки маппинга — точные имена ключей.
        #expect(json["cp_nfc_uid"] as? String == "04A2B3C4D5E680")
        #expect(json["cp_code"] as? String == "9f1a2b3c4d5e6f70")
        #expect(json["checkpoint_id"] as? Int == 264)
        #expect(json["expected_count"] as? Int == 4)
        #expect(json["wall_ms"] as? Int64 == 1_718_900_000_000)
        #expect(json["trusted_ms"] as? Int64 == 1_718_900_000_123)
        #expect(json["elapsed_at"] as? Int64 == 9_876_543)
        #expect(json["boot_count"] as? Int == 7)

        let present = try #require(json["present"] as? [[String: Any]])
        #expect(present.first?["nfc_uid"] as? String == "04F1E2")
        #expect(present.first?["number_in_team"] as? Int == 1)

        let location = try #require(json["location"] as? [String: Any])
        #expect(location["vertical_accuracy"] != nil)
        #expect(location["gps_time_ms"] as? Int64 == 1_718_900_000_001)
    }

    @Test func json_noDefaultScalars_encodeExplicitNull() throws {
        let dto = MarkDto(from: mark(
            present: [1],
            presentDetails: nil, // → sentinel с nil nfc_uid/code
            trustedTakenAt: nil,
            elapsedRealtimeAt: nil,
            bootCount: nil
        ))
        let json = try encodedDict(dto)

        // Явные JSON null (ключ присутствует, значение NSNull) — не пропуск ключа.
        #expect(json.keys.contains("trusted_ms"))
        #expect(json["trusted_ms"] is NSNull)
        #expect(json.keys.contains("elapsed_at"))
        #expect(json["elapsed_at"] is NSNull)
        #expect(json.keys.contains("boot_count"))
        #expect(json["boot_count"] is NSNull)

        let present = try #require(json["present"] as? [[String: Any]])
        let sentinel = try #require(present.first)
        #expect(sentinel.keys.contains("nfc_uid"))
        #expect(sentinel["nfc_uid"] is NSNull)
        #expect(sentinel.keys.contains("code"))
        #expect(sentinel["code"] is NSNull)
        #expect(sentinel["number"] as? Int == 0)
    }

    @Test func json_locationKeyAbsentWhenNoFix() throws {
        let dto = MarkDto(from: mark(present: [1], locLat: nil))
        let json = try encodedDict(dto)
        // `location` имеет Kotlin-default `= null` → ключа НЕТ вовсе (не явный null).
        #expect(!json.keys.contains("location"))
    }

    @Test func json_takeLocationNullableFieldsExplicitNull() throws {
        // Фикс есть (lat/lon), но точность/высота/времена — nil (RawFix без них).
        let m = Mark(
            id: "m",
            raceId: 7,
            teamId: 42,
            checkpointId: 1,
            checkpointNumber: 1,
            cost: 1,
            method: "nfc",
            cpUid: "AA",
            cpCode: "bb",
            present: [1],
            presentDetails: nil,
            expectedCount: 1,
            complete: true,
            takenAt: 1,
            updatedAt: 1,
            locLat: 55.75,
            locLon: 37.61
        )
        let json = try encodedDict(MarkDto(from: m))
        let location = try #require(json["location"] as? [String: Any])
        #expect(location["lat"] as? Double == 55.75)
        #expect(location["accuracy"] is NSNull)
        #expect(location["altitude"] is NSNull)
        #expect(location["vertical_accuracy"] is NSNull)
        #expect(location["gps_time_ms"] is NSNull)
        #expect(location["elapsed_at"] is NSNull)
    }

    @Test func json_request_carriesTeamIdAndSourceInstallId() throws {
        let request = MarkUploadRequest(
            teamId: 42,
            sourceInstallId: "install-abc",
            marks: [MarkDto(from: mark(present: [1]))]
        )
        let data = try JSONEncoder().encode(request)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["team_id"] as? Int == 42)
        #expect(json["source_install_id"] as? String == "install-abc")
        #expect((json["marks"] as? [[String: Any]])?.count == 1)
    }

    // MARK: - Эндпоинт (зеркало ApiClientMarksTest, через FakeTransport)

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

    @Test func uploadMarks_200_returnsAcceptedIds_andPostsBatchToMarksUrl() async throws {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, bodyString: #"{"accepted":["mark-1","mark-2"]}"#)
        let client = makeClient(transport)

        let dto = MarkDto(from: mark(
            present: [1],
            presentDetails: [
                MarkMemberSnapshot(numberInTeam: 1, nfcUid: "04F1E2", number: 101, code: "c3d4"),
            ]
        ))
        let result = await client.uploadMarks(
            raceId: 8, teamId: 42, sourceInstallId: "install-abc", marks: [dto]
        )

        guard case .success(let response) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(response.accepted == ["mark-1", "mark-2"])

        let recorded = try #require(transport.last)
        #expect(recorded.httpMethod == "POST")
        // `URL.path` нормализует и срезает хвостовой слэш — сверяем полный URL (слэш обязателен,
        // он входит в подписанную канонику).
        #expect(recorded.url?.absoluteString == "https://example.test/app/race/8/marks/")
        #expect(recorded.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(recorded.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["team_id"] as? Int == 42)
        #expect(json["source_install_id"] as? String == "install-abc")
        let marks = try #require(json["marks"] as? [[String: Any]])
        #expect(marks.first?["checkpoint_id"] as? Int == 264)
        #expect(marks.first?["cp_nfc_uid"] as? String == "04A2B3C4D5E680")
        #expect(marks.first?["cp_code"] as? String == "9f1a2b3c4d5e6f70")
    }

    @Test func uploadMarks_emptyBatch_postsValidBody_andReturnsAcceptedEmpty() async throws {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, bodyString: #"{"accepted":[]}"#)
        let client = makeClient(transport)

        let result = await client.uploadMarks(
            raceId: 8, teamId: 42, sourceInstallId: "install-abc", marks: []
        )
        guard case .success(let response) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(response.accepted.isEmpty)

        let body = try #require(transport.last?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["team_id"] as? Int == 42)
        #expect((json["marks"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func uploadMarks_201_returnsAcceptedIds() async {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 201, bodyString: #"{"accepted":["mark-1"]}"#)
        let client = makeClient(transport)

        let result = await client.uploadMarks(
            raceId: 8, teamId: 42, sourceInstallId: "install-abc",
            marks: [MarkDto(from: mark(present: [1]))]
        )
        guard case .success(let response) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(response.accepted == ["mark-1"])
    }

    @Test func uploadMarks_401_returnsUnauthorized() async {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 401)
        let result = await makeClient(transport).uploadMarks(
            raceId: 8, teamId: 42, sourceInstallId: "install-abc", marks: []
        )
        if case .unauthorized = result {} else { Issue.record("ожидался .unauthorized, получено \(result)") }
    }

    @Test func uploadMarks_400_returnsBadRequest() async {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 400)
        let result = await makeClient(transport).uploadMarks(
            raceId: 8, teamId: 42, sourceInstallId: "install-abc", marks: []
        )
        if case .badRequest = result {} else { Issue.record("ожидался .badRequest, получено \(result)") }
    }

    @Test func uploadMarks_403_returnsForbidden() async {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 403)
        let result = await makeClient(transport).uploadMarks(
            raceId: 8, teamId: 42, sourceInstallId: "install-abc", marks: []
        )
        if case .forbidden = result {} else { Issue.record("ожидался .forbidden, получено \(result)") }
    }

    @Test func uploadMarks_404_returnsError404() async {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 404)
        let result = await makeClient(transport).uploadMarks(
            raceId: 8, teamId: 42, sourceInstallId: "install-abc", marks: []
        )
        if case .error(let code) = result { #expect(code == 404) }
        else { Issue.record("ожидался .error(404), получено \(result)") }
    }

    @Test func uploadMarks_429_returnsRateLimited() async {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 429)
        let result = await makeClient(transport).uploadMarks(
            raceId: 8, teamId: 42, sourceInstallId: "install-abc", marks: []
        )
        if case .rateLimited = result {} else { Issue.record("ожидался .rateLimited, получено \(result)") }
    }

    @Test func uploadMarks_offline_returnsOffline() async {
        let transport = FakeTransport()
        transport.enqueueError(URLError(.notConnectedToInternet))
        let result = await makeClient(transport).uploadMarks(
            raceId: 8, teamId: 42, sourceInstallId: "install-abc", marks: []
        )
        if case .offline = result {} else { Issue.record("ожидался .offline, получено \(result)") }
    }
}
