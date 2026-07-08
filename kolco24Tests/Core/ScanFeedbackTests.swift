//
//  ScanFeedbackTests.swift
//  kolco24Tests
//
//  Зеркало `ui/scan/ScanFeedbackTest.kt` 1:1: Kp/Member → success,
//  UnboundChip/BadKp → failure, feedbackFor никогда не возвращает neutral.
//

import Testing
@testable import kolco24

struct ScanFeedbackTests {

    @Test func kp_isSuccess() {
        let event = ScanEvent.kp(checkpointId: 1, number: 7, cost: 50, cpUid: "UID", cpCode: "CODE")
        #expect(feedbackFor(event: event) == .success)
    }

    @Test func member_isSuccess() {
        #expect(feedbackFor(event: .member(numberInTeam: 3)) == .success)
    }

    @Test func unboundChip_isFailure() {
        #expect(feedbackFor(event: .unboundChip) == .failure)
    }

    @Test func badKp_isFailure() {
        #expect(feedbackFor(event: .badKp(reason: "неизвестный чип")) == .failure)
    }

    @Test func feedbackFor_neverReturnsNeutral() {
        let events: [ScanEvent] = [
            .kp(checkpointId: 1, number: 7, cost: 50, cpUid: "U", cpCode: "C"),
            .member(numberInTeam: 1),
            .unboundChip,
            .badKp(reason: "reason"),
        ]
        for event in events {
            #expect(feedbackFor(event: event) != .neutral)
        }
    }
}
