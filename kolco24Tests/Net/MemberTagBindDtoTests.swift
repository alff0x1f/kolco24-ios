//
//  MemberTagBindDtoTests.swift
//  kolco24Tests
//
//  Проводной формат `POST /app/race/<id>/member_tags/bind/`: snake_case-ключи, `number` кодируется
//  всегда (явный JSON `null` при `nil` — kotlinx-стиль), декодирование ответа с `code`.
//  Кодирование сверяется через `JSONSerialization` над реально сериализованными байтами.
//

import Foundation
import Testing
@testable import kolco24

struct MemberTagBindDtoTests {

    private func encodedObject(_ request: MemberTagBindRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func request_withNumber_encodesSnakeCaseKeys() throws {
        let obj = try encodedObject(MemberTagBindRequest(nfcUid: "04A1B2C3D4E5F6", number: 101))
        #expect(Set(obj.keys) == ["nfc_uid", "number"])
        #expect(obj["nfc_uid"] as? String == "04A1B2C3D4E5F6")
        #expect(obj["number"] as? Int == 101)
    }

    @Test func request_nilNumber_encodesExplicitNull() throws {
        // Ключ присутствует и равен JSON null (не опущен).
        let obj = try encodedObject(MemberTagBindRequest(nfcUid: "04A1B2C3D4E5F6", number: nil))
        #expect(Set(obj.keys) == ["nfc_uid", "number"])
        #expect(obj["number"] is NSNull)

        let json = String(decoding: try JSONEncoder().encode(
            MemberTagBindRequest(nfcUid: "04A1", number: nil)
        ), as: UTF8.self)
        #expect(json.contains(#""number":null"#))
    }

    @Test func response_decodes_andIgnoresUnknownKeys() throws {
        let body = #"{"number":101,"nfc_uid":"04A1B2C3D4E5F6","code":"00112233445566778899AABBCCDDEEFF","extra":1}"#
        let response = try JSONDecoder().decode(MemberTagBindResponse.self, from: Data(body.utf8))
        #expect(response == MemberTagBindResponse(
            number: 101,
            nfcUid: "04A1B2C3D4E5F6",
            code: "00112233445566778899AABBCCDDEEFF"
        ))
    }

    @Test func response_missingCode_failsToDecode() {
        let body = #"{"number":101,"nfc_uid":"04A1"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MemberTagBindResponse.self, from: Data(body.utf8))
        }
    }
}
