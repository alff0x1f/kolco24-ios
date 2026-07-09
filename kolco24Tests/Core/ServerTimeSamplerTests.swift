//
//  ServerTimeSamplerTests.swift
//  kolco24Tests
//
//  Зеркало `ServerTimeInterceptorTest.kt` (чистая часть — 6 из 9 кейсов принадлежат сэмплеру):
//  Date+RTT midpoint, отсутствующий/битый Date → nil, RTT at-max принят, over-max и
//  отрицательный отброшены. Оставшиеся 3 кейса Kotlin перенацелены (см. план, задача 1):
//    - `cachedResponse_doesNotInvoke` — cache-gate беспредметен при эфемерном транспорте без
//      кэша (зафиксировано конфигом `URLSessionTransport`, задача 8);
//    - `outOfOrderResponses` — покрыт регрессией в `TrustedClockTests`;
//    - `nullBootCount_isForwarded` — вайринг фабрики (задача 8), не сэмплер.
//

import Testing
@testable import kolco24

struct ServerTimeSamplerTests {

    // "Thu, 01 Jan 1970 00:00:10 GMT" парсится ровно в 10_000 мс — однозначно, tz-free.
    private let dateHeader = "Thu, 01 Jan 1970 00:00:10 GMT"
    private let dateEpochMs: Int64 = 10_000

    @Test func networkDate_returnsEpochAndMidpoint() {
        let sample = ServerTimeSampler.sample(
            dateHeader: dateHeader,
            requestElapsedMs: 1_000,
            responseElapsedMs: 1_400 // rtt = 400
        )
        #expect(sample?.serverEpochMs == dateEpochMs)
        #expect(sample?.anchorElapsedMs == 1_200) // 1000 + 400/2
    }

    @Test func missingDateHeader_returnsNil() {
        let sample = ServerTimeSampler.sample(
            dateHeader: nil,
            requestElapsedMs: 1_000,
            responseElapsedMs: 1_400
        )
        #expect(sample == nil)
    }

    @Test func malformedDateHeader_returnsNil() {
        let sample = ServerTimeSampler.sample(
            dateHeader: "not-a-date",
            requestElapsedMs: 1_000,
            responseElapsedMs: 1_400
        )
        #expect(sample == nil)
    }

    @Test func rttAtMax_accepts() {
        let sample = ServerTimeSampler.sample(
            dateHeader: dateHeader,
            requestElapsedMs: 0,
            responseElapsedMs: 10_000 // rtt = 10_000 == maxRttMs
        )
        #expect(sample?.anchorElapsedMs == 5_000) // 0 + 10_000/2
    }

    @Test func rttOverMax_rejects() {
        let sample = ServerTimeSampler.sample(
            dateHeader: dateHeader,
            requestElapsedMs: 0,
            responseElapsedMs: 10_001 // rtt = 10_001 > maxRttMs
        )
        #expect(sample == nil)
    }

    @Test func negativeRtt_rejects() {
        let sample = ServerTimeSampler.sample(
            dateHeader: dateHeader,
            requestElapsedMs: 5_000,
            responseElapsedMs: 4_900 // rtt = -100 (аномалия)
        )
        #expect(sample == nil)
    }

    // MARK: - БОНУС-тесты

    @Test func emptyDateHeader_returnsNil() {
        let sample = ServerTimeSampler.sample(
            dateHeader: "",
            requestElapsedMs: 1_000,
            responseElapsedMs: 1_400
        )
        #expect(sample == nil)
    }

    @Test func zeroRtt_acceptsWithExactAnchor() {
        let sample = ServerTimeSampler.sample(
            dateHeader: dateHeader,
            requestElapsedMs: 2_000,
            responseElapsedMs: 2_000 // rtt = 0
        )
        #expect(sample?.anchorElapsedMs == 2_000) // 2000 + 0/2
        #expect(sample?.serverEpochMs == dateEpochMs)
    }
}
