//
//  DtoDecodingTests.swift
//  kolco24Tests
//
//  Порт-TDD: у 5 wire-DTO (`data/api/dto/*.kt`) НЕТ Android-зеркала на уровне юнит-тестов —
//  kotlinx.serialization доверенная, Kotlin-сторона тестирует только DTO этапа 6 (`JudgeScanDtoTest`,
//  `MarkDtoMappingTest`). Поэтому весь этот сьют — БОНУС-тесты: они фиксируют проводной контракт
//  (`Codable` + точечные `CodingKeys` + forward-compat-дефолты) против JSON-образцов из
//  `kolco24_app_v2/docs/design/API.md` (в iOS-репо этого файла нет — образцы вшиты сюда, тест
//  самодостаточен).
//
//  // MARK: - БОНУС-тесты (Kotlin-зеркала для этих DTO нет)
//

import Testing
import Foundation
@testable import kolco24

struct DtoDecodingTests {

    private let decoder = JSONDecoder()

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: - RacesResponse

    @Test func races_full() throws {
        // Образец `GET /app/races/` из API.md.
        let json = """
        {
          "races": [
            {
              "id": 8,
              "name": "Кольцо24 2026",
              "slug": "kolco24-2026",
              "date": "2026-06-20",
              "date_end": "2026-06-21",
              "place": "Сосновый бор",
              "reg_status": "open"
            }
          ]
        }
        """
        let resp = try decode(RacesResponse.self, json)
        #expect(resp.races.count == 1)
        let r = resp.races[0]
        #expect(r.id == 8)
        #expect(r.name == "Кольцо24 2026")
        #expect(r.slug == "kolco24-2026")
        #expect(r.date == "2026-06-20")
        #expect(r.dateEnd == "2026-06-21")
        #expect(r.place == "Сосновый бор")
        #expect(r.regStatus == "open")
    }

    @Test func race_missingDateEnd_isNil() throws {
        // Минимальный формат: старая гонка без date_end.
        let json = """
        {"races": [
          {"id": 1, "name": "R", "slug": "r", "date": "2026-01-01", "place": "P", "reg_status": "upcoming"}
        ]}
        """
        let resp = try decode(RacesResponse.self, json)
        #expect(resp.races[0].dateEnd == nil)
    }

    @Test func race_mapUrl_present() throws {
        // map_url присутствует → маппится в mapUrl (forward-compat поле, миграция v2).
        let json = """
        {"races": [
          {"id": 8, "name": "R", "slug": "r", "date": "2026-06-20", "place": "P",
           "reg_status": "open", "map_url": "https://cdn.test/8.mbtiles"}
        ]}
        """
        let resp = try decode(RacesResponse.self, json)
        #expect(resp.races[0].mapUrl == "https://cdn.test/8.mbtiles")
    }

    @Test func race_mapUrl_missing_isNil() throws {
        // Ключа map_url нет (сервер без поля) → nil (синтезированный decodeIfPresent).
        let json = """
        {"races": [
          {"id": 1, "name": "R", "slug": "r", "date": "2026-01-01", "place": "P", "reg_status": "upcoming"}
        ]}
        """
        let resp = try decode(RacesResponse.self, json)
        #expect(resp.races[0].mapUrl == nil)
    }

    @Test func race_mapUrl_explicitNull_isNil() throws {
        // Явный null (карты для гонки нет) → nil.
        let json = """
        {"races": [
          {"id": 1, "name": "R", "slug": "r", "date": "2026-01-01", "place": "P",
           "reg_status": "open", "map_url": null}
        ]}
        """
        let resp = try decode(RacesResponse.self, json)
        #expect(resp.races[0].mapUrl == nil)
    }

    @Test func races_empty() throws {
        let resp = try decode(RacesResponse.self, #"{"races": []}"#)
        #expect(resp.races.isEmpty)
    }

    @Test func races_unknownKeys_ignored() throws {
        // Незнакомые ключи (в т.ч. будущие поля) дропаются дефолтом Codable.
        let json = """
        {"races": [
          {"id": 8, "name": "R", "slug": "r", "date": "2026-06-20", "date_end": null,
           "place": "P", "reg_status": "open", "future_field": 42, "nested": {"a": 1}}
        ], "meta": {"page": 1}}
        """
        let resp = try decode(RacesResponse.self, json)
        #expect(resp.races[0].id == 8)
        #expect(resp.races[0].dateEnd == nil)
    }

    // MARK: - TeamsResponse

    @Test func teams_full() throws {
        // Образец `GET /app/race/<id>/teams/` из API.md.
        let json = """
        {
          "race": 8,
          "categories": [
            {"id": 45, "code": "m4", "short_name": "М4", "name": "Мужчины, 4 чел.", "order": 1}
          ],
          "teams": [
            {
              "id": 123,
              "teamname": "Лесные звери",
              "category2": 45,
              "ucount": 4,
              "paid_people": 4.0,
              "start_time": 0,
              "finish_time": 0,
              "members": [
                {"name": "Иванов Иван", "number_in_team": 1},
                {"name": "Петрова Анна", "number_in_team": 2}
              ]
            }
          ]
        }
        """
        let resp = try decode(TeamsResponse.self, json)
        #expect(resp.race == 8)
        #expect(resp.categories.count == 1)
        let cat = resp.categories[0]
        #expect(cat.id == 45)
        #expect(cat.code == "m4")
        #expect(cat.shortName == "М4")
        #expect(cat.name == "Мужчины, 4 чел.")
        #expect(cat.order == 1)
        #expect(resp.teams.count == 1)
        let t = resp.teams[0]
        #expect(t.id == 123)
        #expect(t.teamname == "Лесные звери")
        #expect(t.startNumber == nil)         // ключа нет → nil
        #expect(t.category2 == 45)
        #expect(t.ucount == 4)
        #expect(t.paidPeople == 4.0)          // Double
        #expect(t.startTime == 0)
        #expect(t.finishTime == 0)
        #expect(t.members.map(\.numberInTeam) == [1, 2])
        #expect(t.members[0].name == "Иванов Иван")
    }

    @Test func team_startNumber_null() throws {
        // start_number явно null (Django default="") → nil.
        let json = """
        {"race": 8, "categories": [], "teams": [
          {"id": 1, "teamname": "T", "start_number": null, "category2": null, "ucount": 2,
           "paid_people": 1.5, "start_time": 0, "finish_time": 0, "members": []}
        ]}
        """
        let resp = try decode(TeamsResponse.self, json)
        let t = resp.teams[0]
        #expect(t.startNumber == nil)
        #expect(t.category2 == nil)
        #expect(t.paidPeople == 1.5)
    }

    @Test func team_startNumber_present() throws {
        let json = """
        {"race": 8, "categories": [], "teams": [
          {"id": 1, "teamname": "T", "start_number": "17", "category2": 3, "ucount": 2,
           "paid_people": 2.0, "start_time": 0, "finish_time": 0, "members": []}
        ]}
        """
        let resp = try decode(TeamsResponse.self, json)
        #expect(resp.teams[0].startNumber == "17")
    }

    @Test func team_missingCategory2_throws() throws {
        // Порт-верность: category2 в Kotlin — nullable БЕЗ дефолта → kotlinx.serialization требует
        // наличие ключа (отсутствие → MissingFieldException). Ручной init(from:) с decode(Int?.self)
        // бросает keyNotFound на отсутствующий ключ (иначе битый payload молча стал бы .success).
        let json = """
        {"race": 8, "categories": [], "teams": [
          {"id": 1, "teamname": "T", "ucount": 2, "paid_people": 2.0,
           "start_time": 0, "finish_time": 0, "members": []}
        ]}
        """
        #expect(throws: DecodingError.self) {
            try decode(TeamsResponse.self, json)
        }
    }

    @Test func team_explicitNullCategory2_ok() throws {
        // Явный null допустим (ключ присутствует) — команда не в выдаче.
        let json = """
        {"race": 8, "categories": [], "teams": [
          {"id": 1, "teamname": "T", "category2": null, "ucount": 2, "paid_people": 2.0,
           "start_time": 0, "finish_time": 0, "members": []}
        ]}
        """
        let resp = try decode(TeamsResponse.self, json)
        #expect(resp.teams[0].category2 == nil)
    }

    @Test func team_startFinishTime_areMillis() throws {
        // Ловушка: start_time/finish_time — миллисекунды (Int64), большие значения не переполняют.
        let json = """
        {"race": 8, "categories": [], "teams": [
          {"id": 1, "teamname": "T", "category2": 3, "ucount": 2, "paid_people": 2.0,
           "start_time": 1750000000000, "finish_time": 1750003600000, "members": []}
        ]}
        """
        let resp = try decode(TeamsResponse.self, json)
        let t = resp.teams[0]
        #expect(t.startTime == 1_750_000_000_000)
        #expect(t.finishTime == 1_750_003_600_000)
    }

    // MARK: - LegendResponse

    @Test func legend_full() throws {
        // Образец `GET /app/race/<id>/legend/` из API.md, но тег-ключ — актуальный `checkpoint_id`
        // (в примере API.md устаревший `point`). Открытая + закрытая КП, tags с/без конверта.
        let json = """
        {
          "race": 8,
          "total_cost": 7,
          "scoring_count": 2,
          "checkpoints": [
            {"id": 101, "number": 1, "type": "start", "cost": 1, "description": "Старт, поляна", "color": "green"},
            {"id": 102, "number": 31, "type": "kp", "cost": 3, "description": "Родник у тропы"},
            {"id": 103, "number": 32, "type": "kp", "enc": {"iv": "8f3a", "ct": "b91c"}}
          ],
          "tags": [
            {"bid": "a1b2c3d4e5f60718", "checkpoint_id": 101, "check_method": "nfc", "iv": null, "ct": null},
            {"bid": "9988776655443322", "checkpoint_id": 103, "check_method": "nfc", "iv": "1d2e", "ct": "ff00"}
          ]
        }
        """
        let resp = try decode(LegendResponse.self, json)
        #expect(resp.race == 8)
        #expect(resp.totalCost == 7)
        #expect(resp.scoringCount == 2)
        #expect(resp.checkpoints.count == 3)

        let open = resp.checkpoints[0]
        #expect(open.id == 101)
        #expect(open.number == 1)
        #expect(open.type == "start")
        #expect(open.cost == 1)
        #expect(open.description == "Старт, поляна")
        #expect(open.color == "green")
        #expect(open.enc == nil)

        let noColor = resp.checkpoints[1]
        #expect(noColor.color == nil)         // репозиторий приведёт к ""
        #expect(noColor.enc == nil)

        let locked = resp.checkpoints[2]      // сентинел locked: enc != nil, cost/description отсутствуют
        #expect(locked.cost == nil)
        #expect(locked.description == nil)
        #expect(locked.enc == EncDto(iv: "8f3a", ct: "b91c"))

        #expect(resp.tags.count == 2)
        let openTag = resp.tags[0]
        #expect(openTag.bid == "a1b2c3d4e5f60718")
        #expect(openTag.checkpointId == 101)
        #expect(openTag.checkMethod == "nfc")
        #expect(openTag.iv == nil)
        #expect(openTag.ct == nil)
        let lockTag = resp.tags[1]
        #expect(lockTag.checkpointId == 103)
        #expect(lockTag.iv == "1d2e")
        #expect(lockTag.ct == "ff00")
    }

    @Test func legend_missingAggregatesAndTags_defaults() throws {
        // Forward-compat: total_cost/scoring_count отсутствуют → 0, tags отсутствует → [].
        let json = """
        {"race": 8, "checkpoints": [
          {"id": 101, "number": 1, "type": "start", "cost": 1, "description": "S"}
        ]}
        """
        let resp = try decode(LegendResponse.self, json)
        #expect(resp.totalCost == 0)
        #expect(resp.scoringCount == 0)
        #expect(resp.tags.isEmpty)
        #expect(resp.checkpoints.count == 1)
    }

    @Test func legend_lockedCheckpoint_hasEncNoPlaintext() throws {
        // Изолированно: закрытая КП приходит только с enc, без cost/description.
        let json = """
        {"race": 8, "total_cost": 5, "checkpoints": [
          {"id": 200, "number": 50, "type": "kp", "enc": {"iv": "AAA=", "ct": "BBB="}}
        ]}
        """
        let resp = try decode(LegendResponse.self, json)
        let cp = resp.checkpoints[0]
        #expect(cp.cost == nil)
        #expect(cp.description == nil)
        #expect(cp.color == nil)
        #expect(cp.enc?.iv == "AAA=")
        #expect(cp.enc?.ct == "BBB=")
    }

    @Test func legend_unknownKeys_ignored() throws {
        // Незнакомые ключи в объекте и вложенных элементах игнорируются.
        let json = """
        {"race": 8, "total_cost": 3, "scoring_count": 1, "extra": {"x": 1},
         "checkpoints": [
           {"id": 101, "number": 1, "type": "kp", "cost": 3, "description": "D", "is_legend_locked": false}
         ],
         "tags": [
           {"bid": "abcd", "checkpoint_id": 101, "check_method": "nfc", "point": 101, "iv": null, "ct": null}
         ]}
        """
        let resp = try decode(LegendResponse.self, json)
        #expect(resp.checkpoints[0].cost == 3)
        #expect(resp.tags[0].checkpointId == 101)   // читаем checkpoint_id, устаревший point игнорируется
    }

    // MARK: - MemberTagsResponse

    @Test func memberTags_full() throws {
        // Образец `GET /app/race/<id>/member_tags/` из API.md.
        let json = """
        {
          "member_tags": [
            {"number": 101, "nfc_uid": "04A2B3C4D5E680"},
            {"number": 102, "nfc_uid": "04F1E2D3C4B5A6"}
          ]
        }
        """
        let resp = try decode(MemberTagsResponse.self, json)
        #expect(resp.memberTags.count == 2)
        #expect(resp.memberTags[0].number == 101)
        #expect(resp.memberTags[0].nfcUid == "04A2B3C4D5E680")
        #expect(resp.memberTags[1].number == 102)
        #expect(resp.memberTags[1].nfcUid == "04F1E2D3C4B5A6")
    }

    @Test func memberTags_empty() throws {
        let resp = try decode(MemberTagsResponse.self, #"{"member_tags": []}"#)
        #expect(resp.memberTags.isEmpty)
    }

    // MARK: - SyncManifestDto

    @Test func syncManifest_ignoresVersionsAndParsesNullLease() throws {
        // Образец `GET /app/race/<id>/sync/` из API.md: versions сознательно не маппится, lease поля null.
        let json = """
        {
          "race": 8,
          "data_source": "cloud",
          "lease_expires_at": null,
          "versions": {
            "teams": "a1b2c3d4e5f6a7b8",
            "legend": "0f9e8d7c6b5a4321",
            "member_tags": "77665544aabbccdd"
          }
        }
        """
        let m = try decode(SyncManifestDto.self, json)
        #expect(m.race == 8)
        #expect(m.dataSource == "cloud")
        #expect(m.leaseTtlSeconds == nil)   // ключа нет → nil
        #expect(m.leaseExpiresAt == nil)    // явный null → nil
    }

    @Test func syncManifest_withLeaseValues() throws {
        let json = """
        {"race": 8, "data_source": "local", "lease_ttl_seconds": 3600, "lease_expires_at": 1750000000}
        """
        let m = try decode(SyncManifestDto.self, json)
        #expect(m.dataSource == "local")
        #expect(m.leaseTtlSeconds == 3600)
        #expect(m.leaseExpiresAt == 1_750_000_000)
    }
}
