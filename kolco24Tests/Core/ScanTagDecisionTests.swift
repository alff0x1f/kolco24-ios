//
//  ScanTagDecisionTests.swift
//  kolco24Tests
//
//  Зеркало `ui/scan/ScanTagDecisionTest.kt` (9 кейсов) 1:1: классификация тапа
//  `classifyTag` — revealed/identityOnly → Kp, unknown/failed/null → BadKp,
//  cost==nil / отсутствие в легенде → BadKp, uid в bindings → Member.
//

import Foundation
import Testing
@testable import kolco24

struct ScanTagDecisionTests {

    private let code = Data([0xDE, 0xAD, 0xBE, 0xEF])
    private let uid = "04A2B3C4D5E680"

    private func cp(id: Int, number: Int, cost: Int?) -> Checkpoint {
        Checkpoint(
            id: id,
            raceId: 1,
            number: number,
            cost: cost,
            type: "kp",
            description: cost == nil ? nil : "desc",
            locked: cost == nil
        )
    }

    private var checkpoints: [Int: Checkpoint] {
        [
            42: cp(id: 42, number: 7, cost: 50),
            99: cp(id: 99, number: 12, cost: nil), // легенда не синхронизирована для этого КП
        ]
    }

    @Test func code_revealed_resolvesNumberAndCost() {
        let event = classifyTag(
            code: code,
            uid: uid,
            unlock: .revealed(checkpointId: 42, checkpointIds: [42]),
            bindings: [:],
            checkpointsById: checkpoints
        )
        #expect(event == .kp(checkpointId: 42, number: 7, cost: 50, cpUid: uid, cpCode: "DEADBEEF"))
    }

    @Test func code_identityOnly_resolvesNumberAndCost() {
        let event = classifyTag(
            code: code,
            uid: uid,
            unlock: .identityOnly(checkpointId: 42),
            bindings: [:],
            checkpointsById: checkpoints
        )
        #expect(event == .kp(checkpointId: 42, number: 7, cost: 50, cpUid: uid, cpCode: "DEADBEEF"))
    }

    @Test func code_unknown_badKp() {
        let event = classifyTag(code: code, uid: uid, unlock: .unknown, bindings: [:], checkpointsById: checkpoints)
        if case .badKp = event {} else { Issue.record("expected badKp, got \(event)") }
    }

    @Test func code_failed_badKpCarriesReason() {
        let event = classifyTag(code: code, uid: uid, unlock: .failed(reason: "tamper"), bindings: [:], checkpointsById: checkpoints)
        #expect(event == .badKp(reason: "tamper"))
    }

    @Test func code_costNull_badKp() {
        let event = classifyTag(
            code: code,
            uid: uid,
            unlock: .revealed(checkpointId: 99, checkpointIds: [99]),
            bindings: [:],
            checkpointsById: checkpoints
        )
        #expect(event == .badKp(reason: "легенда не загружена"))
    }

    @Test func code_checkpointMissingFromLegend_badKp() {
        let event = classifyTag(
            code: code,
            uid: uid,
            unlock: .revealed(checkpointId: 777, checkpointIds: [777]),
            bindings: [:],
            checkpointsById: checkpoints
        )
        #expect(event == .badKp(reason: "легенда не загружена"))
    }

    @Test func uid_inBindings_member() {
        let event = classifyTag(
            code: nil,
            uid: uid,
            unlock: nil,
            bindings: [uid: 3],
            checkpointsById: checkpoints
        )
        #expect(event == .member(numberInTeam: 3))
    }

    @Test func uid_notInBindings_unboundChip() {
        let event = classifyTag(
            code: nil,
            uid: uid,
            unlock: nil,
            bindings: ["OTHER": 3],
            checkpointsById: checkpoints
        )
        #expect(event == .unboundChip)
    }

    @Test func code_withNullUnlock_badKp() {
        let event = classifyTag(code: code, uid: uid, unlock: nil, bindings: [:], checkpointsById: checkpoints)
        #expect(event == .badKp(reason: "не удалось расшифровать"))
    }
}
