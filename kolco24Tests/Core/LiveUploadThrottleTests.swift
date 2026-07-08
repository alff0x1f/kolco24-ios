//
//  LiveUploadThrottleTests.swift
//  kolco24Tests
//
//  Зеркало `LiveUploadThrottleTest.kt` (5 кейсов) 1:1: чистый троттл live-загрузок
//  трека `shouldLiveUpload` — дельта ниже/на/выше интервала / ни разу не грузили
//  (первый батч сразу, включая свежий ребут).
//

import Testing
@testable import kolco24

struct LiveUploadThrottleTests {

    @Test func deltaBelowInterval_doesNotUpload() {
        #expect(
            shouldLiveUpload(
                nowElapsed: 599_999,
                lastUploadElapsed: 0,
                minIntervalMs: LIVE_UPLOAD_MIN_INTERVAL_MS
            ) == false
        )
    }

    @Test func deltaAtInterval_uploads() {
        #expect(
            shouldLiveUpload(
                nowElapsed: 600_000,
                lastUploadElapsed: 0,
                minIntervalMs: LIVE_UPLOAD_MIN_INTERVAL_MS
            )
        )
    }

    @Test func deltaAboveInterval_uploads() {
        #expect(
            shouldLiveUpload(
                nowElapsed: 600_001,
                lastUploadElapsed: 0,
                minIntervalMs: LIVE_UPLOAD_MIN_INTERVAL_MS
            )
        )
    }

    @Test func neverUploaded_uploadsRegardlessOfNow() {
        #expect(
            shouldLiveUpload(
                nowElapsed: 999_999_999,
                lastUploadElapsed: nil,
                minIntervalMs: LIVE_UPLOAD_MIN_INTERVAL_MS
            )
        )
    }

    @Test func neverUploaded_justBooted_uploads() {
        // Ребут-край, который сломал бы 0-сентинел: now < interval, но прежней загрузки нет → должно сработать.
        #expect(
            shouldLiveUpload(
                nowElapsed: 5_000,
                lastUploadElapsed: nil,
                minIntervalMs: LIVE_UPLOAD_MIN_INTERVAL_MS
            )
        )
    }
}
