//
//  TrackSamplingTests.swift
//  kolco24Tests
//
//  Свежие тесты чистого даунсемплинга `shouldKeepFix` (зеркала нет — функция новая,
//  не порт). Матрица как у `LiveUploadThrottleTest`: первый фикс всегда сохраняется,
//  дельта ниже/на границе/выше интервала, reboot-edge (маленький nowElapsed +
//  lastKept == nil → true).
//

import Testing
@testable import kolco24

struct TrackSamplingTests {

    @Test func firstFix_alwaysKept() {
        #expect(shouldKeepFix(nowElapsed: 999_999_999, lastKeptElapsed: nil, intervalMs: TRACK_SAMPLE_INTERVAL_MS))
    }

    @Test func deltaBelowInterval_dropped() {
        #expect(!shouldKeepFix(nowElapsed: 14_999, lastKeptElapsed: 0, intervalMs: TRACK_SAMPLE_INTERVAL_MS))
    }

    @Test func deltaAtInterval_kept() {
        #expect(shouldKeepFix(nowElapsed: 15_000, lastKeptElapsed: 0, intervalMs: TRACK_SAMPLE_INTERVAL_MS))
    }

    @Test func deltaAboveInterval_kept() {
        #expect(shouldKeepFix(nowElapsed: 15_001, lastKeptElapsed: 0, intervalMs: TRACK_SAMPLE_INTERVAL_MS))
    }

    @Test func firstFix_justBooted_kept() {
        // Reboot edge, который сломал бы 0-сентинел: nowElapsed < interval, но сохранённого ещё нет → true.
        #expect(shouldKeepFix(nowElapsed: 3_000, lastKeptElapsed: nil, intervalMs: TRACK_SAMPLE_INTERVAL_MS))
    }

    @Test func constantIs15Seconds() {
        #expect(TRACK_SAMPLE_INTERVAL_MS == 15_000)
    }
}
