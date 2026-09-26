//
//  TrackAutoStartTests.swift
//  kolco24Tests
//
//  `AppModel.applyTrackAutoAction`: взятие КП запускает/останавливает запись трека
//  (in-memory env: `NoTrackEngine`, геодоступ разрешён). Выбрана команда 5 гонки 7.
//

import Foundation
import Testing
@testable import kolco24

@MainActor
struct TrackAutoStartTests {

    private func makeModel() async throws -> AppModel {
        let env = try AppEnvironment.inMemory(transport: TrackRecorderTests.RoutingTransport().handle)
        try await env.teamStore.insertTeams([
            Team(id: 5, raceId: 7, teamname: "A", startNumber: "1", categoryId: nil, ucount: 1, paidPeople: 1,
                 startTime: 0, finishTime: 0, members: [TeamMemberItem(name: "Аня", numberInTeam: 1)]),
        ])
        let model = AppModel(env: env)
        await model.start()
        await model.selectTeam(raceId: 7, teamId: 5)
        let deadline = ContinuousClock.now + .seconds(3)
        while model.selectedTeamId != 5, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.selectedTeamId == 5)
        return model
    }

    @Test func startKp_startsRecording() async throws {
        let model = try await makeModel()
        model.applyTrackAutoAction(checkpointType: "start", raceId: 7, teamId: 5)
        #expect(model.trackRecorder.state == .recording(teamId: 5))
    }

    @Test func anyKp_startsRecordingWhenIdle() async throws {
        let model = try await makeModel()
        model.applyTrackAutoAction(checkpointType: "kp", raceId: 7, teamId: 5)
        #expect(model.trackRecorder.state == .recording(teamId: 5))
    }

    @Test func testKp_doesNotStart() async throws {
        let model = try await makeModel()
        model.applyTrackAutoAction(checkpointType: "test", raceId: 7, teamId: 5)
        #expect(model.trackRecorder.state == .idle)
    }

    @Test func testKp_doesNotStop() async throws {
        let model = try await makeModel()
        model.trackRecorder.start(raceId: 7, teamId: 5)
        model.applyTrackAutoAction(checkpointType: "test", raceId: 7, teamId: 5)
        #expect(model.trackRecorder.state == .recording(teamId: 5))
    }

    @Test func finishKp_stopsRecording() async throws {
        let model = try await makeModel()
        model.trackRecorder.start(raceId: 7, teamId: 5)
        model.applyTrackAutoAction(checkpointType: "finish", raceId: 7, teamId: 5)
        #expect(model.trackRecorder.state == .idle)
    }

    @Test func finishKp_whenIdle_staysIdle() async throws {
        let model = try await makeModel()
        model.applyTrackAutoAction(checkpointType: "finish", raceId: 7, teamId: 5)
        #expect(model.trackRecorder.state == .idle)
    }

    @Test func finishKp_ofNotSelectedTeam_doesNotStop() async throws {
        let model = try await makeModel()
        model.trackRecorder.start(raceId: 7, teamId: 5)
        model.applyTrackAutoAction(checkpointType: "finish", raceId: 7, teamId: 6)
        #expect(model.trackRecorder.state == .recording(teamId: 5))
    }

    /// Поздний колбэк скана прежней команды после смены выбора не должен возобновить её запись.
    @Test func takeOfNotSelectedTeam_doesNotStart() async throws {
        let model = try await makeModel()
        model.applyTrackAutoAction(checkpointType: "kp", raceId: 7, teamId: 6)
        model.applyTrackAutoAction(checkpointType: "kp", raceId: 8, teamId: 5)
        #expect(model.trackRecorder.state == .idle)
    }
}
