//
//  BoundCountTests.swift
//  kolco24Tests
//
//  Юнит-тесты чистого хелпера `boundCount(members:bindings:)` (Core/Team/BoundCount.swift) —
//  общий для вкладок «Команда»/«Отметки». Android-зеркала нет (в Kotlin это инлайн-`count`),
//  бонус-suite. Ключевой инвариант: считаются только слоты АКТУАЛЬНОГО ростера, устаревшие
//  привязки удалённых участников не учитываются.
//

import Testing
@testable import kolco24

struct BoundCountTests {

    private func member(_ numberInTeam: Int) -> TeamMemberItem {
        TeamMemberItem(name: "Участник \(numberInTeam)", numberInTeam: numberInTeam)
    }

    private func binding(_ numberInTeam: Int) -> MemberChipBinding {
        MemberChipBinding(teamId: 1, numberInTeam: numberInTeam, nfcUid: "UID\(numberInTeam)", participantNumber: numberInTeam)
    }

    @Test func countsOnlyBoundRosterSlots() {
        let members = [member(1), member(2), member(3)]
        let bindings = [1: binding(1), 3: binding(3)]
        #expect(boundCount(members: members, bindings: bindings) == 2)
    }

    @Test func emptyBindingsYieldZero() {
        #expect(boundCount(members: [member(1), member(2)], bindings: [:]) == 0)
    }

    @Test func emptyRosterYieldsZeroEvenWithBindings() {
        #expect(boundCount(members: [], bindings: [1: binding(1)]) == 0)
    }

    @Test func staleBindingsForDeletedMembersAreIgnored() {
        // Привязка для номера 9, которого больше нет в ростере — не считается.
        let members = [member(1), member(2)]
        let bindings = [1: binding(1), 9: binding(9)]
        #expect(boundCount(members: members, bindings: bindings) == 1)
    }

    @Test func allBoundReturnsFullCount() {
        let members = [member(1), member(2)]
        let bindings = [1: binding(1), 2: binding(2)]
        #expect(boundCount(members: members, bindings: bindings) == 2)
    }
}
