//
//  BindChipDecisionTests.swift
//  kolco24Tests
//
//  Зеркало `ui/team/BindChipDecisionTest.kt` (7 кейсов) 1:1: чистое решение
//  привязки браслета `decideBind` — не в пуле / свободен / привязан к другому
//  слоту / привязан к этому же слоту; poolNumber авторитетнее сохранённого.
//

import Testing
@testable import kolco24

struct BindChipDecisionTests {

    private let slot = SlotKey(teamId: 7, numberInTeam: 2)
    private let uid = "04A2B3C4D5E680"

    @Test func uidNotInPool_notInPool() {
        let outcome = decideBind(uid: uid, poolNumber: nil, existing: nil, currentSlot: slot)
        #expect(outcome == .notInPool)
    }

    @Test func uidNotInPool_takesPrecedenceOverExistingBinding() {
        // Uid, выпавший из пула, должен отказать, даже если некая устаревшая привязка держит его.
        let existing = MemberChipBinding(teamId: 9, numberInTeam: 1, nfcUid: uid, participantNumber: 101)
        let outcome = decideBind(uid: uid, poolNumber: nil, existing: existing, currentSlot: slot)
        #expect(outcome == .notInPool)
    }

    @Test func uidInPool_unbound_readyToBind() {
        let outcome = decideBind(uid: uid, poolNumber: 101, existing: nil, currentSlot: slot)
        #expect(outcome == .readyToBind(participantNumber: 101))
    }

    @Test func uidBoundToAnotherSlot_alreadyBound() {
        let existing = MemberChipBinding(teamId: 7, numberInTeam: 5, nfcUid: uid, participantNumber: 101)
        let outcome = decideBind(uid: uid, poolNumber: 101, existing: existing, currentSlot: slot)
        #expect(outcome == .alreadyBound(otherSlot: SlotKey(teamId: 7, numberInTeam: 5), participantNumber: 101))
    }

    @Test func uidBoundOnAnotherTeamSameNumberInTeam_alreadyBound() {
        // Тот же numberInTeam, но другая команда — всё равно другой слот.
        let existing = MemberChipBinding(teamId: 8, numberInTeam: 2, nfcUid: uid, participantNumber: 101)
        let outcome = decideBind(uid: uid, poolNumber: 101, existing: existing, currentSlot: slot)
        #expect(outcome == .alreadyBound(otherSlot: SlotKey(teamId: 8, numberInTeam: 2), participantNumber: 101))
    }

    @Test func uidAlreadyOnThisSlot_alreadyOnThisSlot() {
        let existing = MemberChipBinding(teamId: 7, numberInTeam: 2, nfcUid: uid, participantNumber: 101)
        let outcome = decideBind(uid: uid, poolNumber: 101, existing: existing, currentSlot: slot)
        #expect(outcome == .alreadyOnThisSlot(participantNumber: 101))
    }

    @Test func alreadyBound_usesPoolNumberNotStoredParticipantNumber() {
        // Пул авторитетен; сохранённый participantNumber может устареть, если пул обновили.
        let existing = MemberChipBinding(teamId: 7, numberInTeam: 5, nfcUid: uid, participantNumber: 99)
        let outcome = decideBind(uid: uid, poolNumber: 101, existing: existing, currentSlot: slot)
        #expect(outcome == .alreadyBound(otherSlot: SlotKey(teamId: 7, numberInTeam: 5), participantNumber: 101))
    }
}
