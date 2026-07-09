//
//  MarkMetricsTests.swift
//  kolco24Tests
//
//  Чистая часть `data/MarkRepositoryTest.kt` — деривации очков (`takenPoints`,
//  `takenPointCount` обе перегрузки, `totalScore` обе перегрузки). В Kotlin эти
//  функции проверяются через DAO-строки, уже зеркалированные `MarkStore`-тестами
//  этапа 2, поэтому здесь — прямые бонус-кейсы на чистые функции (те же сценарии:
//  `derivation_distinctScoredPointsAndScore`, live-cost резолвер, complete-фильтр).
//  Кейсы `takenPointCount(costOf)`/`totalScore(costOf)` из `MarksMappingTest.kt`
//  зеркалятся в `MarksDisplayTests` (файл-владелец маппинга).
//

import Testing
@testable import kolco24

struct MarkMetricsTests {

    private func mark(
        id: String,
        point: Int,
        cost: Int,
        complete: Bool = true
    ) -> Mark {
        Mark(
            id: id,
            raceId: 1,
            teamId: 7,
            checkpointId: point,
            checkpointNumber: point,
            cost: cost,
            method: "nfc",
            cpUid: "UID",
            cpCode: "CODE",
            present: [],
            expectedCount: 0,
            complete: complete,
            takenAt: 1_000,
            updatedAt: 1_000
        )
    }

    // MARK: - БОНУС-тесты (чистые деривации; DAO-кейсы — MarkStore-тесты этапа 2)

    @Test func takenPoints_isSetOfCompleteCheckpointIds() {
        let marks = [
            mark(id: "a", point: 1, cost: 2),
            mark(id: "b", point: 1, cost: 2), // повтор того же пункта
            mark(id: "c", point: 2, cost: 3),
            mark(id: "d", point: 3, cost: 5, complete: false), // не зачтён
        ]
        #expect(takenPoints(marks) == Set([1, 2]))
    }

    @Test func takenPoints_emptyForNoCompleteMarks() {
        #expect(takenPoints([]) == Set<Int>())
        #expect(takenPoints([mark(id: "a", point: 1, cost: 2, complete: false)]) == Set<Int>())
    }

    @Test func derivation_distinctScoredPointsAndScore() {
        // Зеркало сценария `derivation_distinctScoredPointsAndScore` MarkRepositoryTest.
        let marks = [
            mark(id: "a", point: 1, cost: 8),
            mark(id: "b", point: 1, cost: 8), // повтор — не удваивает
            mark(id: "c", point: 2, cost: 5),
            mark(id: "d", point: 3, cost: 7, complete: false), // partial
        ]
        #expect(takenPointCount(marks) == 2)
        #expect(totalScore(marks) == 13)
    }

    @Test func takenPointCount_snapshotOverload_countsDistinctComplete() {
        let marks = [
            mark(id: "a", point: 1, cost: 2),
            mark(id: "b", point: 2, cost: 3),
            mark(id: "c", point: 2, cost: 3), // повтор
            mark(id: "d", point: 3, cost: 5, complete: false),
        ]
        #expect(takenPointCount(marks) == 2)
    }

    @Test func totalScore_snapshotOverload_sumsDistinctComplete() {
        let marks = [
            mark(id: "a", point: 1, cost: 2),
            mark(id: "b", point: 1, cost: 2), // повтор — не удваивает
            mark(id: "c", point: 2, cost: 3),
        ]
        #expect(totalScore(marks) == 5)
    }

    @Test func liveOverloads_agreeWithSnapshotWhenResolverEchoesCost() {
        let marks = [
            mark(id: "a", point: 1, cost: 2),
            mark(id: "b", point: 2, cost: 3),
        ]
        #expect(takenPointCount(marks) { $0.cost } == takenPointCount(marks))
        #expect(totalScore(marks) { $0.cost } == totalScore(marks))
    }
}
