//
//  UploadModelsTests.swift
//  kolco24Tests
//
//  Зеркало upload-части `TrackModelsTest.kt` / `MarkRepositoryUploadTest.kt`:
//  таблица приоритетов `combineOutcome` (все пары) + Equatable-семантика
//  `TargetUploadOutcome`.
//

import Testing
@testable import kolco24

struct UploadModelsTests {

    // MARK: combineOutcome — приоритет error > offline > ok > nil

    @Test func combine_bothNil_isNil() {
        #expect(combineOutcome(nil, nil) == nil)
    }

    @Test func combine_okAlone_isOk() {
        #expect(combineOutcome(.ok, nil) == .ok)
        #expect(combineOutcome(nil, .ok) == .ok)
        #expect(combineOutcome(.ok, .ok) == .ok)
    }

    @Test func combine_offlineBeatsOk() {
        #expect(combineOutcome(.offline, .ok) == .offline)
        #expect(combineOutcome(.ok, .offline) == .offline)
        #expect(combineOutcome(.offline, nil) == .offline)
        #expect(combineOutcome(nil, .offline) == .offline)
        #expect(combineOutcome(.offline, .offline) == .offline)
    }

    @Test func combine_errorBeatsEverything() {
        #expect(combineOutcome(.error, .ok) == .error)
        #expect(combineOutcome(.ok, .error) == .error)
        #expect(combineOutcome(.error, .offline) == .error)
        #expect(combineOutcome(.offline, .error) == .error)
        #expect(combineOutcome(.error, nil) == .error)
        #expect(combineOutcome(nil, .error) == .error)
        #expect(combineOutcome(.error, .error) == .error)
    }

    // MARK: TargetUploadOutcome Equatable

    @Test func outcome_equalWhenSameKindAndWall() {
        let a = TargetUploadOutcome(kind: .ok, atWallMs: 1000)
        let b = TargetUploadOutcome(kind: .ok, atWallMs: 1000)
        #expect(a == b)
    }

    @Test func outcome_differsOnKind() {
        let a = TargetUploadOutcome(kind: .ok, atWallMs: 1000)
        let b = TargetUploadOutcome(kind: .error, atWallMs: 1000)
        #expect(a != b)
    }

    @Test func outcome_differsOnWall() {
        let a = TargetUploadOutcome(kind: .ok, atWallMs: 1000)
        let b = TargetUploadOutcome(kind: .ok, atWallMs: 2000)
        #expect(a != b)
    }
}
