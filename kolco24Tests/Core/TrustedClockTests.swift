//
//  TrustedClockTests.swift
//  kolco24Tests
//
//  Зеркало `data/time/TrustedClockTest.kt` (24 кейса) 1:1: доверенное время как async-actor.
//  Фейковые провайдеры времени + in-memory persist. Все чтения — через `await` к актору.
//  Ветки `bootCount != nil` тоже переносятся (провайдер инъектируется — на проде bootCount = nil).
//

import Testing
@testable import kolco24

struct TrustedClockTests {

    /// Мутабельные инъектируемые источники времени для детерминированного драйва часов.
    private final class Fakes {
        var elapsed: Int64
        var wall: Int64
        var boot: Int?
        var persisted: [ClockAnchor] = []

        init(elapsed: Int64 = 0, wall: Int64 = 0, boot: Int? = 1) {
            self.elapsed = elapsed
            self.wall = wall
            self.boot = boot
        }

        lazy var elapsedProvider: () -> Int64 = { [unowned self] in self.elapsed }
        lazy var wallProvider: () -> Int64 = { [unowned self] in self.wall }
        lazy var bootProvider: () -> Int? = { [unowned self] in self.boot }
        lazy var persist: (ClockAnchor) throws -> Void = { [unowned self] a in self.persisted.append(a) }
    }

    private func clock(
        _ f: Fakes,
        persistedAnchor: ClockAnchor? = nil,
        persist: ((ClockAnchor) throws -> Void)? = nil
    ) -> TrustedClock {
        TrustedClock(
            elapsedProvider: f.elapsedProvider,
            wallProvider: f.wallProvider,
            bootCountProvider: f.bootProvider,
            persist: persist ?? f.persist,
            persisted: persistedAnchor
        )
    }

    @Test func trustedFormula_afterSync() async {
        let f = Fakes(elapsed: 1_000, wall: 5_000_000, boot: 1)
        let c = clock(f)
        // server says epoch = 10_000_000 when monotonic was 1_000.
        await c.onServerTime(serverMs: 10_000_000, anchorElapsed: 1_000, wallNow: 5_000_000, bootNow: 1)
        // advance monotonic by 2 s.
        f.elapsed = 3_000
        #expect(await c.trusted() == 10_002_000)
    }

    @Test func signingSeconds_trustedWhenVerified_wallWhenNoSync() async {
        let f = Fakes(elapsed: 1_000, wall: 5_000_000, boot: 1)
        let c = clock(f)
        // No sync yet → falls back to wall.
        #expect(await c.signingSeconds() == 5_000_000 / 1000)
        await c.onServerTime(serverMs: 10_000_000, anchorElapsed: 1_000, wallNow: 5_000_000, bootNow: 1)
        f.elapsed = 1_000
        #expect(await c.signingSeconds() == 10_000_000 / 1000)
    }

    @Test func warmStart_sameBootCount_trustsImmediatelyWithoutSync() async {
        let f = Fakes(elapsed: 5_000, wall: 0, boot: 7)
        let anchor = ClockAnchor(serverEpochMs: 10_000_000, anchorElapsedMs: 1_000, capturedWallMs: 0, bootCount: 7)
        let c = clock(f, persistedAnchor: anchor)
        // verified at construction; elapsed advanced 4 s since the anchor.
        #expect(await c.trusted() == 10_004_000)
    }

    @Test func warmStart_bothBootNull_doesNotVerify() async {
        let f = Fakes(elapsed: 5_000, wall: 0, boot: nil)
        let anchor = ClockAnchor(serverEpochMs: 10_000_000, anchorElapsedMs: 1_000, capturedWallMs: 0, bootCount: nil)
        let c = clock(f, persistedAnchor: anchor)
        #expect(await c.trusted() == nil)
        #expect(await c.status == .noSync)
    }

    @Test func warmStart_differentBootCount_doesNotVerify() async {
        let f = Fakes(elapsed: 5_000, wall: 0, boot: 8)
        let anchor = ClockAnchor(serverEpochMs: 10_000_000, anchorElapsedMs: 1_000, capturedWallMs: 0, bootCount: 7)
        let c = clock(f, persistedAnchor: anchor)
        #expect(await c.trusted() == nil)
        #expect(await c.status == .noSync)
    }

    @Test func rebootDetect_onRead_monotonicRegression_invalidates() async {
        let f = Fakes(elapsed: 10_000, wall: 0, boot: 5)
        let c = clock(f)
        await c.onServerTime(serverMs: 10_000_000, anchorElapsed: 9_000, wallNow: 0, bootNow: 5)
        #expect(await c.trusted() != nil)
        // Reboot in same process: elapsed resets below the anchor's reading.
        f.elapsed = 100
        #expect(await c.trusted() == nil)
    }

    @Test func p0_bootCountNull_staleAnchorAfterReboot_acceptsNewSyncUnconditionally() async {
        // persisted anchor with a LARGE anchorElapsedMs; both boot ids null so no warm verify and no
        // boot-id reboot signal — only monotonic regression can save us.
        let f = Fakes(elapsed: 50, wall: 0, boot: nil)
        let anchor = ClockAnchor(serverEpochMs: 10_000_000, anchorElapsedMs: 900_000, capturedWallMs: 0, bootCount: nil)
        let c = clock(f, persistedAnchor: anchor)
        // New sync after reboot: small elapsedNow. Must be accepted (regression), not blocked by
        // ordering (incoming anchorElapsed 40 < stale 900_000).
        await c.onServerTime(serverMs: 20_000_000, anchorElapsed: 40, wallNow: 0, bootNow: nil)
        f.elapsed = 60
        #expect(await c.trusted() == 20_000_000 + (60 - 40))
    }

    @Test func initialStatus_verifiedPersisted_isOkNotNoSync() async {
        let f = Fakes(elapsed: 1_000, wall: 10_000_000, boot: 3)
        let anchor = ClockAnchor(serverEpochMs: 10_000_000, anchorElapsedMs: 1_000, capturedWallMs: 10_000_000, bootCount: 3)
        let c = clock(f, persistedAnchor: anchor)
        // wall == trusted at construction → Ok immediately (not NoSync).
        #expect(await c.status == .ok)
    }

    @Test func outOfOrder_lateSmallerAnchorElapsed_sameSession_isRejected() async {
        let f = Fakes(elapsed: 5_000, wall: 0, boot: 1)
        let c = clock(f)
        await c.onServerTime(serverMs: 10_000_000, anchorElapsed: 4_000, wallNow: 0, bootNow: 1)
        // late, out-of-order, smaller anchorElapsed, same session, current monotonically valid.
        await c.onServerTime(serverMs: 99_999_999, anchorElapsed: 1_000, wallNow: 0, bootNow: 1)
        f.elapsed = 4_000
        // still anchored on the first (server 10_000_000 at elapsed 4_000) → trusted == 10_000_000.
        #expect(await c.trusted() == 10_000_000)
    }

    @Test func bootNowNull_doesNotDowngradeGoodAnchor() async {
        let f = Fakes(elapsed: 5_000, wall: 0, boot: 1)
        let c = clock(f)
        await c.onServerTime(serverMs: 10_000_000, anchorElapsed: 4_000, wallNow: 0, bootNow: 1)
        // a later sample where boot id is momentarily unreadable must not invalidate.
        f.boot = nil
        f.elapsed = 6_000
        #expect(await c.trusted() == 10_000_000 + (6_000 - 4_000))
    }

    @Test func scrambledOrder_persistAndStatus_matchWinner_byLargestAnchorElapsed() async {
        let f = Fakes(elapsed: 10_000, wall: 0, boot: 1)
        let c = clock(f)
        // a sequence arriving in scrambled order; winner is the largest anchorElapsed (8_000).
        await c.onServerTime(serverMs: 1, anchorElapsed: 2_000, wallNow: 0, bootNow: 1)
        await c.onServerTime(serverMs: 2, anchorElapsed: 8_000, wallNow: 0, bootNow: 1) // winner
        await c.onServerTime(serverMs: 3, anchorElapsed: 5_000, wallNow: 0, bootNow: 1) // rejected (smaller)
        await c.onServerTime(serverMs: 4, anchorElapsed: 3_000, wallNow: 0, bootNow: 1) // rejected
        let lastPersisted = f.persisted.last!
        #expect(lastPersisted.anchorElapsedMs == 8_000)
        #expect(lastPersisted.serverEpochMs == 2)
        // in-memory anchor agrees with the persisted winner.
        f.elapsed = 8_000
        #expect(await c.trusted() == 2)
    }

    @Test func persist_calledOnAccept() async {
        let f = Fakes(elapsed: 1_000, wall: 0, boot: 1)
        let c = clock(f)
        #expect(f.persisted.isEmpty)
        await c.onServerTime(serverMs: 10_000_000, anchorElapsed: 1_000, wallNow: 0, bootNow: 1)
        #expect(f.persisted.count == 1)
    }

    @Test func persistThrows_onServerTimeDoesNotPropagate_stateStillUpdated() async {
        struct DiskFull: Error {}
        let f = Fakes(elapsed: 1_000, wall: 0, boot: 1)
        let c = clock(f, persist: { _ in throw DiskFull() })
        // must not throw. wall == trusted so status resolves to Ok.
        await c.onServerTime(serverMs: 10_000_000, anchorElapsed: 1_000, wallNow: 10_000_000, bootNow: 1)
        // ref updated and status flow set despite persist failure.
        #expect(await c.trusted() == 10_000_000)
        #expect(await c.status == .ok)
    }

    @Test func skewThreshold_boundaries() async {
        func skewStatusFor(_ skew: Int64) async -> ClockStatus {
            let f = Fakes(elapsed: 1_000, wall: 0, boot: 1)
            let c = clock(f)
            // trusted = serverMs at elapsed==anchor; set wall = trusted + skew.
            await c.onServerTime(serverMs: 1_000_000, anchorElapsed: 1_000, wallNow: 0, bootNow: 1)
            f.wall = 1_000_000 + skew
            await c.recomputeStatus()
            return await c.status
        }
        #expect(await skewStatusFor(59_999) == .ok)
        #expect(await skewStatusFor(60_000) == .ok)
        #expect(await skewStatusFor(60_001) == .skewed(skewMs: 60_001))
    }

    @Test func skewSign_negativeWhenWallBehind() async {
        let f = Fakes(elapsed: 1_000, wall: 0, boot: 1)
        let c = clock(f)
        await c.onServerTime(serverMs: 1_000_000, anchorElapsed: 1_000, wallNow: 0, bootNow: 1)
        f.wall = 1_000_000 - 90_000 // wall 90 s behind trusted.
        await c.recomputeStatus()
        #expect(await c.status == .skewed(skewMs: -90_000))
    }

    @Test func sample_noSync_trustedMsIsNull() async {
        let f = Fakes(elapsed: 1_000, wall: 5_000, boot: 1)
        let c = clock(f)
        // No sync yet — trusted time must be null so MarkRepository persists NULL trustedTakenAt.
        let s = await c.sample()
        #expect(s.trustedMs == nil)
        #expect(s.elapsedMs == 1_000)
        #expect(s.wallMs == 5_000)
    }

    @Test func onServerTime_differentBootId_acceptsNewAnchorUnconditionally() async {
        let f = Fakes(elapsed: 5_000, wall: 0, boot: 1)
        let c = clock(f)
        await c.onServerTime(serverMs: 10_000_000, anchorElapsed: 4_000, wallNow: 0, bootNow: 1)
        #expect(await c.trusted() == 10_000_000 + (5_000 - 4_000))
        // Reboot: boot id changes. New anchor has smaller anchorElapsed but must still be accepted
        // (case c: both boot ids non-null and differ → unconditional accept, same as reboot).
        await c.onServerTime(serverMs: 20_000_000, anchorElapsed: 100, wallNow: 0, bootNow: 2)
        f.boot = 2
        f.elapsed = 200
        #expect(await c.trusted() == 20_000_000 + (200 - 100))
    }

    @Test func trustedAt_pastFix_givesTimeEarlierThanNow_byDeltaElapsed() async {
        let f = Fakes(elapsed: 600_000, wall: 0, boot: 1)
        let c = clock(f)
        // anchor: server 10_000_000 at monotonic 600_000 (== "now").
        await c.onServerTime(serverMs: 10_000_000, anchorElapsed: 600_000, wallNow: 0, bootNow: 1)
        // a fix from a batch ~4 min before now: elapsedAt 360_000 (240 s earlier).
        let at = await c.trustedAt(elapsedAt: 360_000, bootAt: 1)
        let expectedAt: Int64 = 10_000_000 - 240_000
        #expect(at == expectedAt)
        // and it is earlier than "now".
        let now = await c.trusted()
        #expect(at! < now!)
    }

    @Test func trustedAt_preAnchorPoint_sameBootSession_isNotNull() async {
        // Key review case: a point captured BEFORE the network set the anchor (elapsedAt < anchor)
        // in the SAME boot session must extrapolate (NOT be invalidated as a reboot).
        let f = Fakes(elapsed: 5_000, wall: 0, boot: 7)
        let c = clock(f)
        await c.onServerTime(serverMs: 10_000_000, anchorElapsed: 5_000, wallNow: 0, bootNow: 7)
        // point captured at elapsed 2_000, 3 s before the anchor's reading.
        let at = await c.trustedAt(elapsedAt: 2_000, bootAt: 7)
        let expectedAt: Int64 = 10_000_000 - 3_000
        #expect(at != nil)
        #expect(at == expectedAt)
    }

    @Test func trustedAt_differentBootSession_isNull() async {
        let f = Fakes(elapsed: 5_000, wall: 0, boot: 7)
        let c = clock(f)
        await c.onServerTime(serverMs: 10_000_000, anchorElapsed: 5_000, wallNow: 0, bootNow: 7)
        // the fix's boot id differs from the anchor's → cannot compare monotonic scales.
        #expect(await c.trustedAt(elapsedAt: 2_000, bootAt: 8) == nil)
    }

    @Test func trustedAt_bothBootNull_fallsBackToTrustExtrapolate() async {
        // No reboot evidence when either boot id is null → documented fallback: trust & extrapolate.
        let f = Fakes(elapsed: 5_000, wall: 0, boot: nil)
        // warm-start verify requires non-null matching boot, so sync via onServerTime to verify.
        let c = clock(f)
        await c.onServerTime(serverMs: 10_000_000, anchorElapsed: 5_000, wallNow: 0, bootNow: nil)
        #expect(await c.trustedAt(elapsedAt: 2_000, bootAt: nil) == 10_000_000 - 3_000)
    }

    @Test func trustedAt_knownAnchorBoot_nullCallSiteBoot_fallsBackToTrustExtrapolate() async {
        // Anchor has a known boot id; call-site passes null (e.g. bootCountProvider returned null for
        // that fix). A lone null does NOT prove a reboot — documented fallback: trust & extrapolate.
        let f = Fakes(elapsed: 5_000, wall: 0, boot: 7)
        let c = clock(f)
        await c.onServerTime(serverMs: 10_000_000, anchorElapsed: 5_000, wallNow: 0, bootNow: 7)
        #expect(await c.trustedAt(elapsedAt: 2_000, bootAt: nil) == 10_000_000 - 3_000)
    }

    @Test func trustedAt_noSync_isNull() async {
        let f = Fakes(elapsed: 5_000, wall: 0, boot: 1)
        let c = clock(f)
        // never synced → not verified.
        #expect(await c.trustedAt(elapsedAt: 2_000, bootAt: 1) == nil)
    }

    @Test func sample_isConsistentSnapshot() async {
        let f = Fakes(elapsed: 2_000, wall: 5_000, boot: 4)
        let c = clock(f)
        await c.onServerTime(serverMs: 10_000_000, anchorElapsed: 1_000, wallNow: 0, bootNow: 4)
        f.elapsed = 2_000
        let s = await c.sample()
        #expect(s.elapsedMs == 2_000)
        #expect(s.wallMs == 5_000)
        #expect(s.bootCount == 4)
        let expectedTrusted: Int64 = 10_000_000 + (2_000 - 1_000)
        #expect(s.trustedMs == expectedTrusted)
    }
}
