//
//  SyncCoordinatorTests.swift
//  kolco24Tests
//
//  Зеркало `SyncCoordinatorTest.kt` 1:1: ~20 кейсов на фейках-замыканиях с логом вызовов (без БД/сети).
//  `sourceFor` ×2; `probeLocalAndRenew` renew/clear/keep; `enterLocalMode` — вся матрица веток
//  (pin + local fan-out, pin + stale, cloud-source → no-pin, unreachable ничего не пишет, пустой кэш →
//  LAN-races сперва, NoRace, LocalUnreachable при пустом кэше и неуспешном pull, просроченный серверный
//  lease → активный unpin); `exitLocalMode` — always-unpin, offline, unpin без гонки, http/forbidden ≠
//  успех; `refreshAll` — unpinned не трогает LAN, pinned проба затем local, handback во время пробы →
//  cloud, unreachable-проба → остаёмся local; `combineRefreshResults` severity + пустой список.
//

import Foundation
import Testing
@testable import kolco24

private extension SyncSource {
    /// Лог-имя источника 1:1 с котлиновским `SyncSource.name` (`Local`/`Cloud`) для строк call-лога.
    var logName: String { self == .local ? "Local" : "Cloud" }
}

/// Фейки-замыкания с потокобезопасным логом вызовов (fanOut дёргает 4 рефреша параллельно —
/// append под `NSLock`; координатор-`actor` + `nonisolated sourceFor` могут читать/писать lease из
/// разных изоляций, потому `@unchecked Sendable`).
private final class Fakes: @unchecked Sendable {
    var lease: RaceLease?
    var now: Int64 = 0
    var manifest: SyncManifestDto?
    var races: [Race] = []
    var selectedRaceId: Int?
    /// Стреляет на `refreshRaces(.local)`, чтобы тест empty-cache-fallback засеял кэш.
    var onRefreshRacesLocal: (() -> Void)?

    var racesResult: RefreshResult = .updated
    var teamsResult: RefreshResult = .updated
    var legendResult: RefreshResult = .updated
    var memberTagsResult: RefreshResult = .updated

    private let lock = NSLock()
    private var calls: [String] = []
    private func log(_ s: String) { lock.lock(); calls.append(s); lock.unlock() }
    func callLog() -> [String] { lock.lock(); defer { lock.unlock() }; return calls }

    // MARK: - Гейт `fetchSync` (для interleave-теста mutex'а)
    //
    // Когда `gateEnabled`, `fetchSync` виснет на continuation'е, пока тест не вызовет `releaseGate()` —
    // так проба удерживает lease-замок в подвешенном состоянии, а тест запускает конкурентный `exitLocalMode`.
    var gateEnabled = false
    private let gateLock = NSLock()
    private var gateContinuation: CheckedContinuation<Void, Never>?
    private var gateReleased = false
    private var _fetchSyncEntered = false

    func didEnterFetchSync() -> Bool { gateLock.lock(); defer { gateLock.unlock() }; return _fetchSyncEntered }

    private func waitGate() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            gateLock.lock()
            _fetchSyncEntered = true
            if gateReleased {
                gateLock.unlock()
                cont.resume()
            } else {
                gateContinuation = cont
                gateLock.unlock()
            }
        }
    }

    func releaseGate() {
        gateLock.lock()
        gateReleased = true
        let cont = gateContinuation
        gateContinuation = nil
        gateLock.unlock()
        cont?.resume()
    }

    func makeCoordinator() -> SyncCoordinator {
        SyncCoordinator(
            readLease: { self.lease },
            writeLease: { self.lease = $0 },
            nowMs: { self.now },
            fetchSync: { raceId in
                self.log("fetchSync(\(raceId))")
                if self.gateEnabled { await self.waitGate() }
                return self.manifest
            },
            selectedRaceId: { self.selectedRaceId },
            cachedRaces: { self.races },
            refreshRaces: { source in
                self.log("refreshRaces(\(source.logName))")
                if source == .local { self.onRefreshRacesLocal?() }
                return self.racesResult
            },
            refreshTeams: { raceId, source in self.log("refreshTeams(\(raceId),\(source.logName))"); return self.teamsResult },
            refreshLegend: { raceId, source in self.log("refreshLegend(\(raceId),\(source.logName))"); return self.legendResult },
            refreshMemberTags: { raceId, source in self.log("refreshMemberTags(\(raceId),\(source.logName))"); return self.memberTagsResult }
        )
    }
}

// Далёкая дата: `nearestRaceId`'s `effectiveEnd >= today` (реальный wall-clock `todayIso()` внутри
// координатора, не инжектируемый) никогда не устареет, когда бы тест ни запустили.
private func race(_ id: Int) -> Race {
    Race(id: id, name: "Race \(id)", slug: "race-\(id)", date: "2099-01-01", dateEnd: nil, place: "Here", regStatus: "open")
}

private func manifest(race: Int, dataSource: String, ttl: Int64? = nil, expires: Int64? = nil) -> SyncManifestDto {
    SyncManifestDto(race: race, dataSource: dataSource, leaseTtlSeconds: ttl, leaseExpiresAt: expires)
}

struct SyncCoordinatorTests {

    // MARK: sourceFor

    @Test func sourceFor_local_whenPinned() {
        let fakes = Fakes()
        fakes.lease = RaceLease(raceId: 1, expiresAtMs: 10_000)
        fakes.now = 5_000
        #expect(fakes.makeCoordinator().sourceFor(1) == .local)
    }

    @Test func sourceFor_cloud_whenNotPinned() {
        #expect(Fakes().makeCoordinator().sourceFor(1) == .cloud)
    }

    // MARK: probeLocalAndRenew

    @Test func probe_renewsLease_onLocal() async {
        let fakes = Fakes()
        fakes.manifest = manifest(race: 1, dataSource: "local", ttl: 3600)
        fakes.now = 1_000
        let action = await fakes.makeCoordinator().probeLocalAndRenew(1)
        #expect(action == .renew(RaceLease(raceId: 1, expiresAtMs: 1_000 + 3600 * 1000)))
        #expect(fakes.lease == RaceLease(raceId: 1, expiresAtMs: 1_000 + 3600 * 1000))
    }

    @Test func probe_clearsLease_onCloudHandback() async {
        let fakes = Fakes()
        fakes.lease = RaceLease(raceId: 1, expiresAtMs: 10_000)
        fakes.manifest = manifest(race: 1, dataSource: "cloud")
        let action = await fakes.makeCoordinator().probeLocalAndRenew(1)
        #expect(action == .clear)
        #expect(fakes.lease == nil)
    }

    @Test func probe_keepsLease_onUnreachable() async {
        let fakes = Fakes()
        fakes.lease = RaceLease(raceId: 1, expiresAtMs: 10_000)
        fakes.manifest = nil
        let action = await fakes.makeCoordinator().probeLocalAndRenew(1)
        #expect(action == .keep)
        #expect(fakes.lease == RaceLease(raceId: 1, expiresAtMs: 10_000))
    }

    // MARK: enterLocalMode

    @Test func enterLocalMode_pinsAndFansOutLocal_onLocalDataSource() async {
        let fakes = Fakes()
        fakes.selectedRaceId = 7
        fakes.manifest = manifest(race: 7, dataSource: "local", ttl: 3600)
        fakes.now = 1_000
        let outcome = await fakes.makeCoordinator().enterLocalMode()
        #expect(outcome == .pinnedUntil(expiresAtMs: 1_000 + 3600 * 1000, dataStale: false))
        #expect(fakes.lease == RaceLease(raceId: 7, expiresAtMs: 1_000 + 3600 * 1000))
        let calls = fakes.callLog()
        #expect(calls.contains("refreshRaces(Local)"))
        #expect(calls.contains("refreshTeams(7,Local)"))
        #expect(calls.contains("refreshLegend(7,Local)"))
        #expect(calls.contains("refreshMemberTags(7,Local)"))
    }

    @Test func enterLocalMode_pinsButFlagsStale_whenLanFanOutFails() async {
        let fakes = Fakes()
        fakes.selectedRaceId = 7
        fakes.manifest = manifest(race: 7, dataSource: "local", ttl: 3600)
        fakes.now = 1_000
        fakes.teamsResult = .offline
        let outcome = await fakes.makeCoordinator().enterLocalMode()
        #expect(outcome == .pinnedUntil(expiresAtMs: 1_000 + 3600 * 1000, dataStale: true))
        // Пин обязан лечь даже при провале fan-out'а.
        #expect(fakes.lease == RaceLease(raceId: 7, expiresAtMs: 1_000 + 3600 * 1000))
    }

    @Test func enterLocalMode_noPinAndFansOutCloud_onCloudDataSource() async {
        let fakes = Fakes()
        fakes.selectedRaceId = 7
        fakes.manifest = manifest(race: 7, dataSource: "cloud")
        let outcome = await fakes.makeCoordinator().enterLocalMode()
        #expect(outcome == .localNoPin)
        #expect(fakes.lease == nil)
        let calls = fakes.callLog()
        #expect(calls.contains("refreshTeams(7,Cloud)"))
        // Ни один LAN race-scoped ресурс не должен фетчиться на cloud-handback.
        let noLocalRaceScoped = !calls.contains(where: {
            $0 == "refreshTeams(7,Local)" || $0 == "refreshLegend(7,Local)" || $0 == "refreshMemberTags(7,Local)"
        })
        #expect(noLocalRaceScoped)
    }

    @Test func enterLocalMode_writesNothing_whenUnreachable() async {
        let fakes = Fakes()
        fakes.selectedRaceId = 7
        fakes.manifest = nil
        let outcome = await fakes.makeCoordinator().enterLocalMode()
        #expect(outcome == .localUnreachable)
        #expect(fakes.lease == nil)
        // Ничего не должно фетчиться при недоступном LAN.
        let nothingFetched = !fakes.callLog().contains(where: {
            $0.hasPrefix("refreshTeams") || $0.hasPrefix("refreshLegend") ||
                $0.hasPrefix("refreshMemberTags") || $0.hasPrefix("refreshRaces")
        })
        #expect(nothingFetched)
    }

    @Test func enterLocalMode_emptyCache_pullsRacesFromLanFirstThenPins() async {
        let fakes = Fakes()
        fakes.selectedRaceId = nil
        fakes.races = []
        fakes.manifest = manifest(race: 9, dataSource: "local", ttl: 3600)
        fakes.onRefreshRacesLocal = { fakes.races = [race(9)] }

        let outcome = await fakes.makeCoordinator().enterLocalMode()

        // now=0 (по умолчанию), ttl=3600 → expiresAtMs = 3_600_000, fan-out успешен → не stale.
        #expect(outcome == .pinnedUntil(expiresAtMs: 3600 * 1000, dataStale: false))
        #expect(fakes.lease?.raceId == 9)
        #expect(fakes.callLog().contains("refreshTeams(9,Local)"))
    }

    @Test func enterLocalMode_noRace_whenNothingResolvable() async {
        let fakes = Fakes()
        fakes.selectedRaceId = nil
        fakes.races = []
        // LAN races pull успешен (Updated), но реально ничего не вернул.
        let outcome = await fakes.makeCoordinator().enterLocalMode()
        #expect(outcome == .noRace)
    }

    @Test func enterLocalMode_localUnreachable_whenEmptyCacheAndLanRacesPullFails() async {
        let fakes = Fakes()
        fakes.selectedRaceId = nil
        fakes.races = []
        fakes.racesResult = .offline
        // Кэш пуст, потому что сам LAN races pull упал, а не потому что реально пусто —
        // всплыть должно как LocalUnreachable, не как общий NoRace.
        let outcome = await fakes.makeCoordinator().enterLocalMode()
        #expect(outcome == .localUnreachable)
    }

    @Test func enterLocalMode_pastServerLease_isNotSurfacedAsPinned() async {
        let fakes = Fakes()
        fakes.selectedRaceId = 7
        fakes.now = 200_000
        // `lease_expires_at` в прошлом (секунды) — уже истёк на приёме.
        fakes.manifest = manifest(race: 7, dataSource: "local", expires: 100)

        let outcome = await fakes.makeCoordinator().enterLocalMode()

        #expect(outcome == .localNoPin)
        // Должен активно снять lease, а не просто читаться как unpinned.
        #expect(fakes.lease == nil)
        #expect(isPinned(fakes.lease, raceId: 7, nowMs: fakes.now) == false)
    }

    // MARK: exitLocalMode

    @Test func exitLocalMode_alwaysUnpinsAndRefreshesCloud() async {
        let fakes = Fakes()
        fakes.lease = RaceLease(raceId: 7, expiresAtMs: 10_000)
        fakes.selectedRaceId = 7
        let outcome = await fakes.makeCoordinator().exitLocalMode()
        #expect(fakes.lease == nil)
        #expect(outcome == .cloudUpdated)
        let calls = fakes.callLog()
        #expect(calls.contains("refreshTeams(7,Cloud)"))
        #expect(calls.contains("refreshLegend(7,Cloud)"))
        #expect(calls.contains("refreshMemberTags(7,Cloud)"))
    }

    @Test func exitLocalMode_offline_whenCloudUnreachable() async {
        let fakes = Fakes()
        fakes.lease = RaceLease(raceId: 7, expiresAtMs: 10_000)
        fakes.selectedRaceId = 7
        fakes.racesResult = .offline
        fakes.teamsResult = .offline
        fakes.legendResult = .offline
        fakes.memberTagsResult = .offline
        let outcome = await fakes.makeCoordinator().exitLocalMode()
        #expect(outcome == .offline)
        // Снимает пин даже когда cloud-refresh упал.
        #expect(fakes.lease == nil)
    }

    @Test func exitLocalMode_unpinsEvenWithNoResolvableRace() async {
        let fakes = Fakes()
        fakes.lease = RaceLease(raceId: 7, expiresAtMs: 10_000)
        fakes.selectedRaceId = nil
        fakes.races = []
        let outcome = await fakes.makeCoordinator().exitLocalMode()
        #expect(fakes.lease == nil)
        #expect(outcome == .cloudUpdated)
        #expect(fakes.callLog().contains("refreshRaces(Cloud)"))
    }

    @Test func exitLocalMode_httpError_isNotReportedAsCloudUpdated() async {
        let fakes = Fakes()
        fakes.lease = RaceLease(raceId: 7, expiresAtMs: 10_000)
        fakes.selectedRaceId = 7
        fakes.teamsResult = .httpError(500)
        let outcome = await fakes.makeCoordinator().exitLocalMode()
        #expect(fakes.lease == nil)
        #expect(outcome == .offline)
    }

    @Test func exitLocalMode_forbidden_isNotReportedAsCloudUpdated() async {
        let fakes = Fakes()
        fakes.lease = RaceLease(raceId: 7, expiresAtMs: 10_000)
        fakes.selectedRaceId = 7
        fakes.legendResult = .forbidden
        let outcome = await fakes.makeCoordinator().exitLocalMode()
        #expect(fakes.lease == nil)
        #expect(outcome == .offline)
    }

    // MARK: refreshAll

    @Test func refreshAll_unpinned_neverTouchesLan() async {
        let fakes = Fakes()
        let result = await fakes.makeCoordinator().refreshAll(7)
        #expect(result == .updated)
        let noLan = !fakes.callLog().contains(where: { $0.hasSuffix(",Local)") })
        #expect(noLan)
    }

    @Test func refreshAll_pinned_probesThenFansOutLocal_whenStillPinned() async {
        let fakes = Fakes()
        fakes.lease = RaceLease(raceId: 7, expiresAtMs: 10_000)
        fakes.now = 1_000
        fakes.manifest = manifest(race: 7, dataSource: "local", ttl: 3600)
        let result = await fakes.makeCoordinator().refreshAll(7)
        #expect(result == .updated)
        #expect(fakes.callLog().contains("refreshTeams(7,Local)"))
        #expect(fakes.lease == RaceLease(raceId: 7, expiresAtMs: 1_000 + 3600 * 1000))
    }

    @Test func refreshAll_pinned_fallsBackToCloud_onHandbackDuringProbe() async {
        let fakes = Fakes()
        fakes.lease = RaceLease(raceId: 7, expiresAtMs: 10_000)
        fakes.now = 1_000
        fakes.manifest = manifest(race: 7, dataSource: "cloud")
        let result = await fakes.makeCoordinator().refreshAll(7)
        #expect(result == .updated)
        #expect(fakes.lease == nil)
        let calls = fakes.callLog()
        #expect(calls.contains("refreshTeams(7,Cloud)"))
        let noLocalTeams = !calls.contains(where: { $0 == "refreshTeams(7,Local)" })
        #expect(noLocalTeams)
    }

    @Test func refreshAll_pinned_staysLocal_whenProbeUnreachable() async {
        // Потеря связи во время mid-pull пробы никогда не снимает пин — fan-out всё равно
        // роутит Local по (неизменному) сохранённому lease.
        let fakes = Fakes()
        fakes.lease = RaceLease(raceId: 7, expiresAtMs: 10_000)
        fakes.now = 1_000
        fakes.manifest = nil
        let result = await fakes.makeCoordinator().refreshAll(7)
        #expect(result == .updated)
        #expect(fakes.lease == RaceLease(raceId: 7, expiresAtMs: 10_000))
        let calls = fakes.callLog()
        #expect(calls.contains("refreshTeams(7,Local)"))
        let noCloudTeams = !calls.contains(where: { $0 == "refreshTeams(7,Cloud)" })
        #expect(noCloudTeams)
    }

    // MARK: lease-замок (сериализация поперёк await)

    /// Порт семантики `leaseMutex.withLock`: `exitLocalMode`, стартовавший, пока проба висит на
    /// `fetchSync`, обязан ЛЕЧЬ ПОСЛЕ пробы — иначе stale renew пробы ре-пинил бы гонку, которую
    /// пользователь только что открепил. С замком выключение — последнее → гонка не запинена.
    @Test func exitDuringSuspendedProbe_leavesRaceUnpinned() async {
        let fakes = Fakes()
        // Пользователь запинен; проба вернула бы renew (ре-пин), если бы легла после exit.
        fakes.lease = RaceLease(raceId: 7, expiresAtMs: 1_000_000)
        fakes.now = 1_000
        fakes.selectedRaceId = 7
        fakes.manifest = manifest(race: 7, dataSource: "local", ttl: 3600)
        fakes.gateEnabled = true
        let coordinator = fakes.makeCoordinator()

        // Проба стартует и виснет на `fetchSync`, удерживая lease-замок.
        let probe = Task { await coordinator.probeLocalAndRenew(7) }
        while !fakes.didEnterFetchSync() { await Task.yield() }

        // Пользователь выключает LAN: `exit` должен встать в очередь за замком, а не проехать.
        let exit = Task { await coordinator.exitLocalMode() }
        // Дать exit'у шанс попытаться захватить замок (без замка он бы уже записал nil и завис на fanOut).
        try? await Task.sleep(for: .milliseconds(50))

        // Отпускаем пробу: она renew'ит (ре-пин), отдаёт замок, затем exit снимает пин последним.
        fakes.releaseGate()
        _ = await probe.value
        _ = await exit.value

        #expect(fakes.lease == nil)
        #expect(isPinned(fakes.lease, raceId: 7, nowMs: fakes.now) == false)
    }

    /// Отменённый ждущий замка (задача-подписчик пересоздаётся) не должен позже провести lease/сетевые
    /// мутации, а сам замок обязан остаться исправным. probe1 держит замок (висит на `fetchSync`), probe2
    /// встаёт в очередь и отменяется — он не выполняет тело (ни одного лишнего `fetchSync`), lease отражает
    /// только probe1, а последующий захват замка работает.
    @Test func cancelledWaiter_doesNotMutateLease_andLockStaysUsable() async {
        let fakes = Fakes()
        fakes.lease = nil
        fakes.now = 1_000
        fakes.manifest = manifest(race: 7, dataSource: "local", ttl: 3600)
        fakes.gateEnabled = true
        let coordinator = fakes.makeCoordinator()

        // probe1 захватывает замок и виснет на `fetchSync` (гейт).
        let probe1 = Task { await coordinator.probeLocalAndRenew(7) }
        while !fakes.didEnterFetchSync() { await Task.yield() }

        // probe2 встаёт в очередь за замком (fetchSync ещё НЕ вызывал — заблокирован на замке).
        let probe2 = Task { await coordinator.probeLocalAndRenew(7) }
        try? await Task.sleep(for: .milliseconds(50))

        // Отменяем ждущего probe2 и дожидаемся его ДО отпускания probe1: пока probe1 держит замок,
        // единственный путь возобновления probe2 — `cancelWaiter` (не hand-off) → `.keep`, тело не бежит.
        probe2.cancel()
        let cancelled = await probe2.value
        #expect(cancelled == .keep)

        // Отпускаем probe1: он renew'ит lease и снимает замок (пропуская уже снятого ждущего).
        fakes.releaseGate()
        _ = await probe1.value

        // Ровно один `fetchSync(7)` — probe1; отменённый probe2 тела не выполнил.
        #expect(fakes.callLog().filter { $0 == "fetchSync(7)" }.count == 1)
        #expect(fakes.lease == RaceLease(raceId: 7, expiresAtMs: 1_000 + 3600 * 1000))

        // Замок исправен: последующий захват работает (cloud-handback чистит lease).
        fakes.manifest = manifest(race: 7, dataSource: "cloud")
        let after = await coordinator.probeLocalAndRenew(7)
        #expect(after == .clear)
        #expect(fakes.lease == nil)
        #expect(fakes.callLog().filter { $0 == "fetchSync(7)" }.count == 2)
    }

    // MARK: combineRefreshResults

    @Test func combineRefreshResults_severityOrder() {
        #expect(combineRefreshResults([.forbidden, .httpError(500), .updated]) == .httpError(500))
        #expect(combineRefreshResults([.offline, .forbidden, .skipped]) == .forbidden)
        #expect(combineRefreshResults([.offline, .updated, .notModified]) == .offline)
        #expect(combineRefreshResults([.updated, .notModified, .skipped]) == .updated)
        #expect(combineRefreshResults([.notModified, .skipped]) == .notModified)
        #expect(combineRefreshResults([.skipped]) == .skipped)
    }

    @Test func combineRefreshResults_emptyList_isVacuouslySkipped() {
        #expect(combineRefreshResults([]) == .skipped)
    }
}
