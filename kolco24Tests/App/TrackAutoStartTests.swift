//
//  TrackAutoStartTests.swift
//  kolco24Tests
//
//  `AppModel.applyTrackAutoAction`: взятие КП запускает/останавливает запись трека
//  (in-memory env: `NoTrackEngine`, геодоступ разрешён).
//

import Foundation
import Testing
@testable import kolco24

@MainActor
struct TrackAutoStartTests {

    private func makeModel() throws -> AppModel {
        AppModel(env: try AppEnvironment.inMemory(transport: FakeTransport().handle))
    }

    @Test func startKp_startsRecording() throws {
        let model = try makeModel()
        model.applyTrackAutoAction(checkpointType: "start", raceId: 7, teamId: 5)
        #expect(model.trackRecorder.state == .recording(teamId: 5))
    }

    @Test func anyKp_startsRecordingWhenIdle() throws {
        let model = try makeModel()
        model.applyTrackAutoAction(checkpointType: "kp", raceId: 7, teamId: 5)
        #expect(model.trackRecorder.state == .recording(teamId: 5))
    }

    @Test func testKp_doesNotStart() throws {
        let model = try makeModel()
        model.applyTrackAutoAction(checkpointType: "test", raceId: 7, teamId: 5)
        #expect(model.trackRecorder.state == .idle)
    }

    @Test func testKp_doesNotStop() throws {
        let model = try makeModel()
        model.trackRecorder.start(raceId: 7, teamId: 5)
        model.applyTrackAutoAction(checkpointType: "test", raceId: 7, teamId: 5)
        #expect(model.trackRecorder.state == .recording(teamId: 5))
    }

    @Test func finishKp_stopsRecording() throws {
        let model = try makeModel()
        model.trackRecorder.start(raceId: 7, teamId: 5)
        model.applyTrackAutoAction(checkpointType: "finish", raceId: 7, teamId: 5)
        #expect(model.trackRecorder.state == .idle)
    }

    @Test func finishKp_whenIdle_staysIdle() throws {
        let model = try makeModel()
        model.applyTrackAutoAction(checkpointType: "finish", raceId: 7, teamId: 5)
        #expect(model.trackRecorder.state == .idle)
    }

    @Test func finishKp_doesNotStopOtherTeam() throws {
        let model = try makeModel()
        model.trackRecorder.start(raceId: 7, teamId: 6)
        model.applyTrackAutoAction(checkpointType: "finish", raceId: 7, teamId: 5)
        #expect(model.trackRecorder.state == .recording(teamId: 6))
    }
}
