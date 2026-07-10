//
//  PhotoStorageLogicTests.swift
//  kolco24Tests
//
//  Зеркало `data/marks/PhotoStorageTest.kt` (чистые `scaledDimensions`/
//  `orphanPhotoDirs`; имена кейсов 1:1). Дисковый/ImageIO-адаптер
//  (`Photo/PhotoStorage.swift`) кроется I/O-тестами во временном каталоге
//  (`kolco24Tests/Photo/PhotoStorageTests`, Task 3).
//

import Testing
@testable import kolco24

struct PhotoStorageLogicTests {

    // MARK: - scaledDimensions

    @Test func scaledDimensionsLeavesSmallImageUnchanged() {
        #expect(scaledDimensions(width: 800, height: 600, maxEdge: 1600) == (800, 600))
        #expect(scaledDimensions(width: 1600, height: 1200, maxEdge: 1600) == (1600, 1200))
    }

    @Test func scaledDimensionsShrinksLandscapeToCapOnLongestEdge() {
        // 4000x3000 → длиннейшая 4000 скейлится в 1600 → 1600x1200.
        #expect(scaledDimensions(width: 4000, height: 3000, maxEdge: 1600) == (1600, 1200))
    }

    @Test func scaledDimensionsShrinksPortraitToCapOnLongestEdge() {
        // 3000x4000 → длиннейшая 4000 скейлится в 1600 → 1200x1600.
        #expect(scaledDimensions(width: 3000, height: 4000, maxEdge: 1600) == (1200, 1600))
    }

    @Test func scaledDimensionsNeverYieldsZeroEdge() {
        let (w, h) = scaledDimensions(width: 4000, height: 1, maxEdge: 1600)
        #expect(w == 1600)
        #expect(h == 1)
    }

    @Test func scaledDimensionsHandlesNonPositiveInput() {
        #expect(scaledDimensions(width: 0, height: 0, maxEdge: 1600) == (0, 0))
        #expect(scaledDimensions(width: -1, height: 10, maxEdge: 1600) == (-1, 10))
    }

    // MARK: - orphanPhotoDirs

    @Test func orphanPhotoDirsReturnsDirsWithNoLiveMark() {
        let dirs = ["m1", "m2", "m3"]
        let known: Set<String> = ["m2"]
        #expect(orphanPhotoDirs(dirNames: dirs, liveMarkIds: known) == ["m1", "m3"])
    }

    @Test func orphanPhotoDirsEmptyWhenAllKnown() {
        let dirs = ["m1", "m2"]
        #expect(orphanPhotoDirs(dirNames: dirs, liveMarkIds: ["m1", "m2"]) == [])
    }

    @Test func orphanPhotoDirsAllOrphanWhenNoneKnown() {
        let dirs = ["m1", "m2"]
        #expect(orphanPhotoDirs(dirNames: dirs, liveMarkIds: []) == dirs)
    }
}
