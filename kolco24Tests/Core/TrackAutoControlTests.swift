//
//  TrackAutoControlTests.swift
//  kolco24Tests
//
//  `trackAutoAction`: тип КП → старт/стоп записи трека (iOS-only, зеркала нет).
//

import Testing
@testable import kolco24

struct TrackAutoControlTests {

    @Test func start_starts() {
        #expect(trackAutoAction(checkpointType: "start") == .start)
    }

    @Test func regularKp_starts() {
        #expect(trackAutoAction(checkpointType: "kp") == .start)
    }

    @Test func unknownType_starts() {
        #expect(trackAutoAction(checkpointType: "") == .start)
    }

    @Test func finish_stops() {
        #expect(trackAutoAction(checkpointType: "finish") == .stop)
    }

    @Test func test_isIgnored() {
        #expect(trackAutoAction(checkpointType: "test") == nil)
    }
}
