//
//  ResolvePhotoCheckpointTests.swift
//  kolco24Tests
//
//  Зеркало `data/marks/ResolvePhotoCheckpointTest.kt` (4 кейса) 1:1: разрешение
//  номера КП против легенды — известный / неизвестный / пустая легенда /
//  locked-КП всё же разрешается (сценарий «метку сорвали»).
//

import Testing
@testable import kolco24

struct ResolvePhotoCheckpointTests {

    private func cp(
        id: Int,
        number: Int,
        cost: Int? = 5,
        locked: Bool = false
    ) -> Checkpoint {
        Checkpoint(
            id: id,
            raceId: 1,
            number: number,
            cost: cost,
            type: "kp",
            description: locked ? nil : "desc",
            locked: locked
        )
    }

    private var legend: [Checkpoint] {
        [
            cp(id: 10, number: 1),
            cp(id: 20, number: 2),
            cp(id: 30, number: 3, cost: nil, locked: true),
        ]
    }

    @Test func knownNumberResolvesToItsCheckpoint() {
        #expect(resolvePhotoCheckpoint(number: 2, legend: legend) == legend[1])
    }

    @Test func unknownNumberResolvesToNull() {
        #expect(resolvePhotoCheckpoint(number: 99, legend: legend) == nil)
    }

    @Test func emptyLegendResolvesToNull() {
        #expect(resolvePhotoCheckpoint(number: 1, legend: []) == nil)
    }

    @Test func lockedCheckpointStillResolves() {
        let resolved = resolvePhotoCheckpoint(number: 3, legend: legend)

        #expect(resolved == legend[2])
        #expect(resolved?.cost == nil)
    }
}
