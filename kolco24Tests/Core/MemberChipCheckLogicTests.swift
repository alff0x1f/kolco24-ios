//
//  MemberChipCheckLogicTests.swift
//  kolco24Tests
//
//  Зеркало `ui/admin/MemberChipCheckModelTest.kt` → `Core/Admin/ChipCheckLogic.classifyMemberChipCheck`
//  (этап 10). Имена кейсов 1:1. Порядок веток: пул побеждает KP-код → kpChip → unknown. Свифт-сигнатура
//  берёт `memberNumber: Int?` (идиома `classifyJudgeScan`) вместо Kotlin-`MemberTagEntity?`.
//

import Foundation
import Testing
@testable import kolco24

struct MemberChipCheckLogicTests {

    @Test func classify_uidInPool_isOk() {
        let result = classifyMemberChipCheck(uid: "0411223344AABB", memberNumber: 123, hasKpCode: false)
        #expect(result == .ok(uid: "0411223344AABB", number: 123))
    }

    @Test func classify_uidInPool_winsOverKpCode() {
        // Синхронизированный пул авторитетен: пулный UID — Ok, даже если чип несёт код.
        let result = classifyMemberChipCheck(uid: "0411223344AABB", memberNumber: 7, hasKpCode: true)
        #expect(result == .ok(uid: "0411223344AABB", number: 7))
    }

    @Test func classify_notInPool_withKpCode_isKpChip() {
        let result = classifyMemberChipCheck(uid: "DEADBEEF", memberNumber: nil, hasKpCode: true)
        #expect(result == .kpChip(uid: "DEADBEEF"))
    }

    @Test func classify_notInPool_noCode_isUnknown() {
        let result = classifyMemberChipCheck(uid: "DEADBEEF", memberNumber: nil, hasKpCode: false)
        #expect(result == .unknown(uid: "DEADBEEF"))
    }
}
