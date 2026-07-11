//
//  JudgeScanLogicTests.swift
//  kolco24Tests
//
//  Зеркало `ui/admin/JudgeScanModelTest.kt` (5 classify-кейсов, имена 1:1) + свежие кейсы
//  на маппинг полей `makeJudgeScan` (включая nil trusted/boot). `memberTag: MemberTagEntity?`
//  Kotlin-теста адаптирован в `memberNumber: Int?` (хост резолвит номер до классификации).
//

import Foundation
import Testing
@testable import kolco24

struct JudgeScanLogicTests {

    // MARK: classifyJudgeScan (зеркало JudgeScanModelTest.kt)

    @Test
    func classify_poolNotReady_shortCircuitsEvenWhenMemberTagWouldMatch() {
        let result = classifyJudgeScan(
            uid: "0411223344AABB",
            memberNumber: 123,
            hasKpCode: false,
            poolReady: false
        )
        #expect(result == .poolNotReady)
    }

    @Test
    func classify_poolNotReady_shortCircuitsEvenWithKpCode() {
        let result = classifyJudgeScan(
            uid: "DEADBEEF",
            memberNumber: nil,
            hasKpCode: true,
            poolReady: false
        )
        #expect(result == .poolNotReady)
    }

    @Test
    func classify_pooledUid_isRecorded() {
        let result = classifyJudgeScan(
            uid: "0411223344AABB",
            memberNumber: 123,
            hasKpCode: false,
            poolReady: true
        )
        #expect(result == .recorded(uid: "0411223344AABB", number: 123))
    }

    @Test
    func classify_pooledUid_winsOverKpCode() {
        let result = classifyJudgeScan(
            uid: "0411223344AABB",
            memberNumber: 7,
            hasKpCode: true,
            poolReady: true
        )
        #expect(result == .recorded(uid: "0411223344AABB", number: 7))
    }

    @Test
    func classify_notInPool_withKpCode_isKpChip() {
        let result = classifyJudgeScan(
            uid: "DEADBEEF",
            memberNumber: nil,
            hasKpCode: true,
            poolReady: true
        )
        #expect(result == .kpChip)
    }

    @Test
    func classify_notInPool_noCode_isUnknownChip() {
        let result = classifyJudgeScan(
            uid: "DEADBEEF",
            memberNumber: nil,
            hasKpCode: false,
            poolReady: true
        )
        #expect(result == .unknownChip(uid: "DEADBEEF"))
    }

    // MARK: makeJudgeScan (свежие — маппинг полей семпла)

    @Test
    func makeJudgeScan_mapsSampleAndScalarFields() {
        let sample = TimeSample(wallMs: 1_700_000_000_000, elapsedMs: 42_000, trustedMs: 1_700_000_000_500, bootCount: 3)
        let scan = makeJudgeScan(
            id: "scan-1",
            raceId: 5,
            eventType: "start",
            participantNumber: 217,
            nfcUid: "0411223344AABB",
            sample: sample,
            sourceInstallId: "install-xyz"
        )

        #expect(scan.id == "scan-1")
        #expect(scan.raceId == 5)
        #expect(scan.eventType == "start")
        #expect(scan.participantNumber == 217)
        #expect(scan.nfcUid == "0411223344AABB")
        #expect(scan.takenAt == 1_700_000_000_000)
        #expect(scan.trustedTakenAt == 1_700_000_000_500)
        #expect(scan.elapsedRealtimeAt == 42_000)
        #expect(scan.bootCount == 3)
        #expect(scan.sourceInstallId == "install-xyz")
        // write-once: флаги загрузки стартуют false.
        #expect(scan.uploadedLocal == false)
        #expect(scan.uploadedCloud == false)
    }

    @Test
    func makeJudgeScan_nilTrustedAndBootPassThrough() {
        let sample = TimeSample(wallMs: 111, elapsedMs: 222, trustedMs: nil, bootCount: nil)
        let scan = makeJudgeScan(
            id: "scan-2",
            raceId: 1,
            eventType: "finish",
            participantNumber: 4,
            nfcUid: "AABB",
            sample: sample,
            sourceInstallId: "iid"
        )

        #expect(scan.eventType == "finish")
        #expect(scan.takenAt == 111)
        #expect(scan.elapsedRealtimeAt == 222)
        #expect(scan.trustedTakenAt == nil)
        #expect(scan.bootCount == nil)
    }
}
