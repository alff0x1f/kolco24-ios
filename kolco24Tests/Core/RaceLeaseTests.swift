//
//  RaceLeaseTests.swift
//  kolco24Tests
//
//  Зеркало `RaceLeaseTest.kt` 1:1: приоритет истечения lease (TTL > absolute > 12 ч дефолт),
//  границы `isPinned` (строгое `<`, чужая гонка, просроченный серверный lease), матрица
//  `applySyncResponse` (renew/clear/keep для nil-манифеста / чужой гонки / неизвестного source).
//  `applySyncResponse` в Swift принимает разобранные поля манифеста (не DTO — `Core/` без `Net/`),
//  манифест-`nil` → `race: nil`.
//

import Testing
@testable import kolco24

struct RaceLeaseTests {

    // MARK: renewedLease precedence

    @Test func renewedLease_prefersTtl_overAbsoluteAndDefault() {
        let lease = renewedLease(raceId: 1, serverTtlSec: 3600, serverLeaseExpiresAtSec: 999, nowMs: 10_000)
        #expect(lease == RaceLease(raceId: 1, expiresAtMs: 10_000 + 3600 * 1000))
    }

    @Test func renewedLease_fallsBackToAbsolute_whenTtlNull() {
        let lease = renewedLease(raceId: 1, serverTtlSec: nil, serverLeaseExpiresAtSec: 5_000, nowMs: 10_000)
        #expect(lease == RaceLease(raceId: 1, expiresAtMs: 5_000 * 1000))
    }

    @Test func renewedLease_fallsBackToClientDefault_whenBothNull() {
        let lease = renewedLease(raceId: 1, serverTtlSec: nil, serverLeaseExpiresAtSec: nil, nowMs: 10_000)
        #expect(lease == RaceLease(raceId: 1, expiresAtMs: 10_000 + DEFAULT_LEASE_MS))
    }

    // MARK: renewedLease overflow (deviation от Kotlin: насыщение вместо трапа/wrap)

    /// Огромный, но валидный `lease_ttl_seconds` из LAN-манифеста не должен ронять приложение
    /// (Swift `*`/`+` ТРАПят, Kotlin `Long` оборачивается) — считаем с насыщением к `Int64.max`.
    @Test func renewedLease_saturatesToMax_onTtlOverflow() {
        let lease = renewedLease(raceId: 1, serverTtlSec: Int64.max, serverLeaseExpiresAtSec: nil, nowMs: 1_000)
        #expect(lease.expiresAtMs == Int64.max)
        #expect(isPinned(lease, raceId: 1, nowMs: 1_000)) // насыщенный lease ведёт себя как «бессрочный»
    }

    /// Переполнение по `nowMs + ttl*1000` (само умножение в пределах, а сложение — нет) тоже
    /// насыщается, а не трапает.
    @Test func renewedLease_saturatesToMax_onNowPlusTtlOverflow() {
        let lease = renewedLease(raceId: 1, serverTtlSec: 1, serverLeaseExpiresAtSec: nil, nowMs: Int64.max - 100)
        #expect(lease.expiresAtMs == Int64.max)
    }

    /// Огромный `lease_expires_at` (absolute epoch-сек) тоже насыщается при `* 1000`.
    @Test func renewedLease_saturatesToMax_onAbsoluteExpiryOverflow() {
        let lease = renewedLease(raceId: 1, serverTtlSec: nil, serverLeaseExpiresAtSec: Int64.max, nowMs: 1_000)
        #expect(lease.expiresAtMs == Int64.max)
    }

    // MARK: isPinned

    @Test func isPinned_true_whenRaceMatchesAndNotExpired() {
        let lease = RaceLease(raceId: 1, expiresAtMs: 10_000)
        #expect(isPinned(lease, raceId: 1, nowMs: 9_999))
    }

    @Test func isPinned_false_whenNullLease() {
        #expect(isPinned(nil, raceId: 1, nowMs: 0) == false)
    }

    @Test func isPinned_false_whenRaceMismatch() {
        let lease = RaceLease(raceId: 1, expiresAtMs: 10_000)
        #expect(isPinned(lease, raceId: 2, nowMs: 0) == false)
    }

    @Test func isPinned_false_atExpiryBoundary() {
        let lease = RaceLease(raceId: 1, expiresAtMs: 10_000)
        #expect(isPinned(lease, raceId: 1, nowMs: 10_000) == false)
    }

    @Test func isPinned_false_pastExpiry() {
        let lease = RaceLease(raceId: 1, expiresAtMs: 10_000)
        #expect(isPinned(lease, raceId: 1, nowMs: 10_001) == false)
    }

    @Test func isPinned_false_forPastServerLease() {
        // Серверный lease, уже в прошлом на момент приёма, никогда не должен читаться как активный пин.
        let lease = renewedLease(raceId: 1, serverTtlSec: nil, serverLeaseExpiresAtSec: 100, nowMs: 200_000)
        #expect(isPinned(lease, raceId: 1, nowMs: 200_000) == false)
    }

    // MARK: applySyncResponse

    @Test func applySyncResponse_renews_onLocal() {
        let action = applySyncResponse(race: 1, dataSource: "local", ttlSec: 3600, expiresAtSec: nil, raceId: 1, nowMs: 10_000)
        #expect(action == .renew(RaceLease(raceId: 1, expiresAtMs: 10_000 + 3600 * 1000)))
    }

    @Test func applySyncResponse_clears_onCloud() {
        let action = applySyncResponse(race: 1, dataSource: "cloud", ttlSec: nil, expiresAtSec: nil, raceId: 1, nowMs: 10_000)
        #expect(action == .clear)
    }

    @Test func applySyncResponse_keeps_onNullManifest() {
        let action = applySyncResponse(race: nil, dataSource: nil, ttlSec: nil, expiresAtSec: nil, raceId: 1, nowMs: 10_000)
        #expect(action == .keep)
    }

    @Test func applySyncResponse_keeps_onManifestForAnotherRace() {
        let action = applySyncResponse(race: 2, dataSource: "local", ttlSec: 3600, expiresAtSec: nil, raceId: 1, nowMs: 10_000)
        #expect(action == .keep)
    }

    @Test func applySyncResponse_keeps_onUnknownDataSource() {
        let action = applySyncResponse(race: 1, dataSource: "mirror", ttlSec: nil, expiresAtSec: nil, raceId: 1, nowMs: 10_000)
        #expect(action == .keep)
    }
}
