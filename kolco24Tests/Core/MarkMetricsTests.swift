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
        complete: Bool = true,
        checkMethod: String = "offline",
        confirmedAt: Int64? = nil
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
            updatedAt: 1_000,
            checkMethod: checkMethod,
            confirmedAt: confirmedAt
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

    // MARK: - check method (iOS-only): зачёт по isCounted, а не по complete

    @Test func metricsExcludeUnconfirmedCloudTake() {
        let marks = [
            mark(id: "a", point: 1, cost: 2),                                   // offline
            mark(id: "b", point: 2, cost: 3, checkMethod: "cloud"),             // не подтверждён
            mark(id: "c", point: 3, cost: 5, checkMethod: "local"),             // не подтверждён
        ]
        #expect(takenPoints(marks) == Set([1]))
        #expect(takenPointCount(marks) == 1)
        #expect(takenPointCount(marks) { $0.cost } == 1)
        #expect(totalScore(marks) == 2)
        #expect(totalScore(marks) { $0.cost } == 2)
    }

    @Test func metricsIncludeConfirmedCloudAndLocalTakes() {
        let marks = [
            mark(id: "a", point: 1, cost: 2),
            mark(id: "b", point: 2, cost: 3, checkMethod: "cloud", confirmedAt: 9_000),
            mark(id: "c", point: 3, cost: 5, checkMethod: "local", confirmedAt: 9_000),
        ]
        #expect(takenPoints(marks) == Set([1, 2, 3]))
        #expect(takenPointCount(marks) == 3)
        #expect(takenPointCount(marks) { $0.cost } == 3)
        #expect(totalScore(marks) == 10)
        #expect(totalScore(marks) { $0.cost } == 10)
    }

    @Test func confirmedRetakeCountsPointOnceAlongsideUnconfirmedTake() {
        // Новейшее взятие подтверждено, старое — нет: КП зачтён один раз.
        let marks = [
            mark(id: "new", point: 2, cost: 3, checkMethod: "cloud", confirmedAt: 9_000),
            mark(id: "old", point: 2, cost: 3, checkMethod: "cloud"),
        ]
        #expect(takenPoints(marks) == Set([2]))
        #expect(takenPointCount(marks) == 1)
        #expect(totalScore(marks) == 3)
    }

    @Test func unknownCheckMethodCountsAsOffline() {
        let marks = [mark(id: "a", point: 1, cost: 2, checkMethod: "online")]
        #expect(takenPointCount(marks) == 1)
        #expect(totalScore(marks) == 2)
    }
}
