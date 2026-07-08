//
//  SegmentIdTests.swift
//  kolco24Tests
//
//  Зеркало `SegmentIdTest.kt` (5 кейсов) 1:1: чистое решение минта id сегмента
//  записи `nextSegmentId` — fresh-start / идемпотентный повтор (mint не зовётся) /
//  teardown в полёте / stop→start даёт два разных сегмента.
//

import Testing
@testable import kolco24

struct SegmentIdTests {

    @Test func freshStart_nullCurrent_mintsNew() {
        let result = nextSegmentId(current: nil, wasTearingDown: false) { "minted" }
        #expect(result == "minted")
    }

    @Test func idempotentReEntry_keepsCurrent() {
        var minted = false
        let result = nextSegmentId(current: "existing", wasTearingDown: false) {
            minted = true
            return "minted"
        }
        #expect(result == "existing")
        // mint не должен даже вызываться на keep-пути
        #expect(minted == false)
    }

    @Test func teardownInFlight_replacesWithNew_evenWhenCurrentNonNull() {
        let result = nextSegmentId(current: "existing", wasTearingDown: true) { "minted" }
        #expect(result == "minted")
    }

    @Test func teardownInFlight_nullCurrent_mintsNew() {
        let result = nextSegmentId(current: nil, wasTearingDown: true) { "minted" }
        #expect(result == "minted")
    }

    @Test func stopThenStart_producesTwoDistinctSegments() {
        var n = 0
        let mint = { () -> String in
            defer { n += 1 }
            return "seg-\(n)"
        }
        // Первая сессия.
        let first = nextSegmentId(current: nil, wasTearingDown: false, mint: mint)
        // finishTeardown() сбросил segmentId в nil; следующий старт минтит свежий.
        let second = nextSegmentId(current: nil, wasTearingDown: false, mint: mint)
        #expect(first != second)
    }
}
