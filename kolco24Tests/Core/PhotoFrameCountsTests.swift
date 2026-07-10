//
//  PhotoFrameCountsTests.swift
//  kolco24Tests
//
//  Зеркало `PhotoFrameCountsTest.kt` — свёртка `foldPhotoFrameCounts` с гранулярностью
//  «тик по марке, знаменатель по кадрам».
//

import Testing
@testable import kolco24

struct PhotoFrameCountsTests {

    private func row(count: Int, local: Bool, cloud: Bool) -> PhotoFrameInput {
        let paths = count > 0 ? (1...count).map { "marks/m/\($0).jpg" } : []
        return PhotoFrameInput(
            photoPath: PhotoPaths.encode(paths),
            local: local,
            cloud: cloud
        )
    }

    @Test func emptyList_yieldsZeroCounts() {
        let counts = foldPhotoFrameCounts([])
        #expect(counts.total == 0)
        #expect(counts.local == 0)
        #expect(counts.cloud == 0)
    }

    @Test func rowWithEmptyEncodedList_contributesNoFrames() {
        let counts = foldPhotoFrameCounts([row(count: 0, local: true, cloud: true)])
        #expect(counts.total == 0)
        #expect(counts.local == 0)
        #expect(counts.cloud == 0)
    }

    @Test func singleMarkBothFlagsSet_countsAllFramesOnBothTargets() {
        let counts = foldPhotoFrameCounts([row(count: 3, local: true, cloud: true)])
        #expect(counts.total == 3)
        #expect(counts.local == 3)
        #expect(counts.cloud == 3)
    }

    @Test func midDrainMark_contributesToTotalButNotToEitherNumerator() {
        let counts = foldPhotoFrameCounts([row(count: 4, local: false, cloud: false)])
        #expect(counts.total == 4)
        #expect(counts.local == 0)
        #expect(counts.cloud == 0)
    }

    @Test func mixedRows_sumAsymmetricallyPerTarget() {
        let rows = [
            row(count: 2, local: true, cloud: false),
            row(count: 5, local: false, cloud: true),
        ]
        let counts = foldPhotoFrameCounts(rows)
        #expect(counts.total == 7)
        #expect(counts.local == 2)
        #expect(counts.cloud == 5)
    }
}
