//
//  TrustedNowTests.swift
//  kolco24Tests
//
//  iOS-only (Kotlin-источника нет): `trustedNowMs` — skew вычитается только при `.skewed`.
//

import Testing
@testable import kolco24

struct TrustedNowTests {

    private static let min: Int64 = 60_000
    private static let hour: Int64 = 60 * min
    private static let t0: Int64 = 1_700_000_000_000

    @Test func trustedNow_subtractsSkewOnlyWhenSkewed() {
        #expect(trustedNowMs(wallMs: Self.t0, clock: .skewed(skewMs: 5 * Self.min)) == Self.t0 - 5 * Self.min)
        #expect(trustedNowMs(wallMs: Self.t0, clock: .skewed(skewMs: -Self.hour)) == Self.t0 + Self.hour)
        #expect(trustedNowMs(wallMs: Self.t0, clock: .ok) == Self.t0)
        #expect(trustedNowMs(wallMs: Self.t0, clock: .noSync) == Self.t0)
    }
}
