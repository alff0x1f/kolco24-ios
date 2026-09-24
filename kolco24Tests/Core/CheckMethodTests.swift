//
//  CheckMethodTests.swift
//  kolco24Tests
//
//  iOS-only (Kotlin-источника нет): разбор `CheckMethod`, маппинг `uploadTarget`,
//  матрица `isCounted` / `isUnconfirmed` (complete × метод × confirmedAt).
//

import Testing
@testable import kolco24

struct CheckMethodTests {

    private func mark(complete: Bool, checkMethod: String, confirmedAt: Int64?) -> Mark {
        Mark(
            id: "m",
            raceId: 1,
            teamId: 7,
            checkpointId: 1,
            checkpointNumber: 1,
            cost: 2,
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

    @Test func parsesKnownValues() {
        #expect(CheckMethod("offline") == .offline)
        #expect(CheckMethod("cloud") == .cloud)
        #expect(CheckMethod("local") == .local)
    }

    @Test func unknownValuesParseAsOffline() {
        #expect(CheckMethod("nfc") == .offline)
        #expect(CheckMethod("online") == .offline)
        #expect(CheckMethod("local_server") == .offline)
        #expect(CheckMethod("") == .offline)
        #expect(CheckMethod("Cloud") == .offline)
    }

    @Test func uploadTargetMapping() {
        #expect(CheckMethod.offline.uploadTarget == nil)
        #expect(CheckMethod.cloud.uploadTarget == .cloud)
        #expect(CheckMethod.local.uploadTarget == .local)
    }

    @Test(arguments: [
        // (complete, method, confirmedAt, counted, unconfirmed)
        (true, "offline", nil as Int64?, true, false),
        (true, "offline", 5 as Int64?, true, false),
        (false, "offline", nil as Int64?, false, false),
        (true, "cloud", nil as Int64?, false, true),
        (true, "cloud", 5 as Int64?, true, false),
        (false, "cloud", nil as Int64?, false, false),
        (false, "cloud", 5 as Int64?, false, false),
        (true, "local", nil as Int64?, false, true),
        (true, "local", 5 as Int64?, true, false),
        (false, "local", nil as Int64?, false, false),
        (true, "nfc", nil as Int64?, true, false),
    ])
    func countedAndUnconfirmedMatrix(
        _ c: (Bool, String, Int64?, Bool, Bool)
    ) {
        let m = mark(complete: c.0, checkMethod: c.1, confirmedAt: c.2)
        #expect(isCounted(m) == c.3)
        #expect(isUnconfirmed(m) == c.4)
    }
}
