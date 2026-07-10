//
//  CurrentLocationTests.swift
//  kolco24Tests
//
//  Чистые хелперы one-shot GPS-шва: `sanitizeFix` (зеркало веток
//  `MarkRepository.attachLocation`) и `isFixFresh` (зеркало
//  `LegacyCurrentLocationProvider.isFresh`). Провайдер — платформенная граница
//  (устройство), здесь тестируется только чистая логика.
//

import Testing
@testable import kolco24

struct CurrentLocationTests {

    private func fix(
        lat: Double = 55.75,
        lon: Double = 37.62,
        accuracy: Float = 5,
        altitude: Double? = 150,
        verticalAccuracy: Float? = 3,
        gpsTimeMs: Int64 = 1_700_000_000_000,
        elapsedRealtimeNanos: Int64 = 12_000_000_000
    ) -> RawFix {
        RawFix(
            lat: lat,
            lon: lon,
            accuracy: accuracy,
            altitude: altitude,
            verticalAccuracyMeters: verticalAccuracy,
            gpsTimeMs: gpsTimeMs,
            elapsedRealtimeNanos: elapsedRealtimeNanos
        )
    }

    // MARK: sanitizeFix

    @Test func sanitizeValidFixKeepsAllColumns() {
        let s = sanitizeFix(fix())
        #expect(s.lat == 55.75)
        #expect(s.lon == 37.62)
        #expect(s.accuracy == 5)
        #expect(s.altitude == 150)
        #expect(s.verticalAccuracyMeters == 3)
        #expect(s.gpsTimeMs == 1_700_000_000_000)
        // 12_000_000_000 нс → 12_000 мс.
        #expect(s.elapsedRealtimeAt == 12_000)
    }

    @Test func sanitizeDropsSentinelAccuracy() {
        let s = sanitizeFix(fix(accuracy: .greatestFiniteMagnitude))
        #expect(s.accuracy == nil)
    }

    @Test func sanitizeKeepsFiniteAccuracyIncludingZero() {
        #expect(sanitizeFix(fix(accuracy: 0)).accuracy == 0)
        #expect(sanitizeFix(fix(accuracy: 49.9)).accuracy == 49.9)
    }

    @Test func sanitizeDropsNonPositiveGpsTime() {
        #expect(sanitizeFix(fix(gpsTimeMs: 0)).gpsTimeMs == nil)
        #expect(sanitizeFix(fix(gpsTimeMs: -5)).gpsTimeMs == nil)
    }

    @Test func sanitizeKeepsPositiveGpsTime() {
        #expect(sanitizeFix(fix(gpsTimeMs: 1)).gpsTimeMs == 1)
    }

    @Test func sanitizePropagatesNilOptionals() {
        let s = sanitizeFix(fix(altitude: nil, verticalAccuracy: nil))
        #expect(s.altitude == nil)
        #expect(s.verticalAccuracyMeters == nil)
    }

    @Test func sanitizeConvertsNanosToMillisTruncating() {
        // 12_000_999_999 нс / 1_000_000 = 12_000 (целочисленное усечение).
        let s = sanitizeFix(fix(elapsedRealtimeNanos: 12_000_999_999))
        #expect(s.elapsedRealtimeAt == 12_000)
    }

    // MARK: isFixFresh

    @Test func freshWhenWithinWindow() {
        // Фикс в 12_000 мс, сейчас 15_000 мс → возраст 3_000 мс ≤ 10_000.
        let f = fix(elapsedRealtimeNanos: 12_000_000_000)
        #expect(isFixFresh(f, nowElapsedNanos: 15_000_000_000))
    }

    @Test func staleWhenBeyondWindow() {
        // Возраст 11_000 мс > 10_000.
        let f = fix(elapsedRealtimeNanos: 12_000_000_000)
        #expect(!isFixFresh(f, nowElapsedNanos: 23_000_000_000))
    }

    @Test func freshAtExactWindowBoundary() {
        // Возраст ровно 10_000 мс → в диапазоне 0..10_000 (включительно).
        let f = fix(elapsedRealtimeNanos: 12_000_000_000)
        #expect(isFixFresh(f, nowElapsedNanos: 22_000_000_000))
    }

    @Test func freshAtZeroAge() {
        let f = fix(elapsedRealtimeNanos: 12_000_000_000)
        #expect(isFixFresh(f, nowElapsedNanos: 12_000_000_000))
    }

    @Test func staleWhenFixInFuture() {
        // Отрицательный возраст (фикс монотонно позже «сейчас») — не свеж.
        let f = fix(elapsedRealtimeNanos: 12_000_000_000)
        #expect(!isFixFresh(f, nowElapsedNanos: 11_000_000_000))
    }

    @Test func customMaxAgeHonored() {
        let f = fix(elapsedRealtimeNanos: 12_000_000_000)
        // Возраст 3_000 мс: свеж при пороге 3_000, не свеж при пороге 2_999.
        #expect(isFixFresh(f, nowElapsedNanos: 15_000_000_000, maxAgeMs: 3_000))
        #expect(!isFixFresh(f, nowElapsedNanos: 15_000_000_000, maxAgeMs: 2_999))
    }
}
