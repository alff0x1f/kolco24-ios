//
//  FilterCheckpointsByQueryTests.swift
//  kolco24Tests
//
//  Зеркало `data/marks/FilterCheckpointsByQueryTest.kt` (7 кейсов) 1:1: фильтр
//  легенды по свободному тексту — пустой запрос / подстрока номера / регистр
//  описания / locked без описания по номеру / нет совпадений.
//

import Testing
@testable import kolco24

struct FilterCheckpointsByQueryTests {

    private func cp(
        id: Int,
        number: Int,
        description: String? = "desc",
        locked: Bool = false
    ) -> Checkpoint {
        Checkpoint(
            id: id,
            raceId: 1,
            number: number,
            cost: locked ? nil : 5,
            type: "kp",
            description: description,
            locked: locked
        )
    }

    private var legend: [Checkpoint] {
        [
            cp(id: 10, number: 1, description: "Развилка у озера"),
            cp(id: 20, number: 12, description: "Мост"),
            cp(id: 30, number: 23, description: nil, locked: true),
        ]
    }

    @Test func blankQueryReturnsWholeLegendInOrder() {
        #expect(filterCheckpointsByQuery(legend: legend, query: "") == legend)
        #expect(filterCheckpointsByQuery(legend: legend, query: "   ") == legend)
    }

    @Test func numberSubstringMatches() {
        // "2" встречается в 12 и 23, но не в 1.
        #expect(filterCheckpointsByQuery(legend: legend, query: "2") == [legend[1], legend[2]])
    }

    @Test func query1IsASubstringMatchHittingTwoCheckpoints() {
        // "1" — подстрока и 1, и 12 — проверяет корректность размера результата, а не только наличие
        // одного элемента (сломанная реализация, вернувшая все 3, прошла бы find-based проверку).
        let result = filterCheckpointsByQuery(legend: legend, query: "1")
        #expect(result.count == 2)
        #expect(result == [legend[0], legend[1]])
    }

    @Test func query12MatchesOnlyCheckpoint12() {
        #expect(filterCheckpointsByQuery(legend: legend, query: "12") == [legend[1]])
    }

    @Test func descriptionMatchesCaseInsensitively() {
        #expect(filterCheckpointsByQuery(legend: legend, query: "мост") == [legend[1]])
    }

    @Test func lockedCheckpointWithoutDescriptionStillMatchesOnNumber() {
        #expect(filterCheckpointsByQuery(legend: legend, query: "23") == [legend[2]])
    }

    @Test func noMatchReturnsEmpty() {
        #expect(filterCheckpointsByQuery(legend: legend, query: "999") == [])
    }
}
