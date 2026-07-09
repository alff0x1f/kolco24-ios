//
//  TeamMembersCodecTests.swift
//  kolco24Tests
//
//  Зеркало Android `TeamMembersConverterTest` (JVM). Проверяет кодек JSON-колонки
//  `teams.members` (`TeamMembersCodec`, порт `TeamMembersConverter`): round-trip
//  сохраняет участников/порядок, пустой список. Плюс бонус-проверка порт-ловушки —
//  JSON-ключ `number_in_team` (Kotlin `@SerialName`).
//

import Foundation
import Testing
@testable import kolco24

struct TeamMembersCodecTests {

    @Test func roundTripPreservesMembersAndOrder() {
        let members = [
            TeamMemberItem(name: "Иван", numberInTeam: 1),
            TeamMemberItem(name: "Пётр", numberInTeam: 2),
            TeamMemberItem(name: "Анна", numberInTeam: 3),
        ]
        let restored = TeamMembersCodec.decode(TeamMembersCodec.encode(members))
        #expect(restored == members)
    }

    @Test func roundTripEmptyList() {
        let restored = TeamMembersCodec.decode(TeamMembersCodec.encode([]))
        #expect(restored.isEmpty)
    }

    // Бонус (нет в Kotlin-тесте): порт-ловушка — JSON-ключ `number_in_team`
    // (Kotlin `@SerialName("number_in_team")`). Иначе распарсенный с сервера JSON
    // не смапится на слот участника.
    @Test func encodesNumberInTeamWithServerKey() {
        let json = TeamMembersCodec.encode([TeamMemberItem(name: "Иван", numberInTeam: 7)])
        #expect(json.contains("number_in_team"))
        #expect(!json.contains("numberInTeam"))
    }

    @Test func decodesServerKeyNumberInTeam() {
        let json = #"[{"name":"Иван","number_in_team":7}]"#
        let restored = TeamMembersCodec.decode(json)
        #expect(restored == [TeamMemberItem(name: "Иван", numberInTeam: 7)])
    }

    @Test func malformedInputReturnsEmptyList() {
        #expect(TeamMembersCodec.decode("not-json").isEmpty)
    }
}
