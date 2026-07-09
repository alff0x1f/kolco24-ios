//
//  MemberTagsRepositoryTests.swift
//  kolco24Tests
//
//  Зеркало `data/MemberTagsRepositoryTest.kt` (32 кейса) поверх РЕАЛЬНЫХ store'ов над
//  `AppDatabase.makeInMemory()` (конвенция этапа 2 — без фейков) + `FakeTransport` (замена
//  `MockWebServer`). Всё из `TeamRepositoryTests` (refresh + pin-guard) ПЛЮС synced-маркер во всех
//  вариантах (200 без ETag, 304, forbidden, кросс-origin) и `hasBeenSynced`/`observeHasBeenSynced`.
//

import Foundation
import GRDB
import Testing
@testable import kolco24

struct MemberTagsRepositoryTests {

    private let cloudOrigin = "https://cloud.test"
    private let localOrigin = "http://local.test"

    // MARK: - Фикстуры

    private func memberTagsJson(_ uids: [(Int, String)] = [(101, "04A2B3C4D5E680")]) -> String {
        var s = #"{"member_tags":["#
        for (index, pair) in uids.enumerated() {
            if index > 0 { s += "," }
            s += #"{"number":\#(pair.0),"nfc_uid":"\#(pair.1)"}"#
        }
        s += "]}"
        return s
    }

    private func makeApiClient(baseURL: String, transport: FakeTransport) -> ApiClient {
        ApiClient(
            baseURL: baseURL,
            keyId: "ios-v1",
            secret: "test-secret-123",
            installId: "install-abc",
            appVersion: "2.0.1",
            nowSeconds: { 1_718_200_000 },
            elapsedNowMs: { 0 },
            onServerTime: nil,
            tokenProvider: { nil },
            transport: transport.handle
        )
    }

    private struct Harness {
        let repo: MemberTagsRepository
        let dbWriter: any DatabaseWriter
        let memberTagStore: MemberTagStore
        let syncMetaStore: SyncMetaStore
        let cloudTransport: FakeTransport
        let localTransport: FakeTransport
    }

    private func makeHarness(
        dbWriter: any DatabaseWriter,
        isRacePinned: @escaping (Int) -> Bool = { _ in false }
    ) -> Harness {
        let cloudTransport = FakeTransport()
        let localTransport = FakeTransport()
        let memberTagStore = MemberTagStore(dbWriter)
        let syncMetaStore = SyncMetaStore(dbWriter)
        let repo = MemberTagsRepository(
            apiClient: makeApiClient(baseURL: cloudOrigin, transport: cloudTransport),
            memberTagStore: memberTagStore,
            syncMetaStore: syncMetaStore,
            origin: cloudOrigin,
            localApiClient: makeApiClient(baseURL: localOrigin, transport: localTransport),
            localOrigin: localOrigin,
            isRacePinned: isRacePinned
        )
        return Harness(
            repo: repo,
            dbWriter: dbWriter,
            memberTagStore: memberTagStore,
            syncMetaStore: syncMetaStore,
            cloudTransport: cloudTransport,
            localTransport: localTransport
        )
    }

    private func makeHarness(
        isRacePinned: @escaping (Int) -> Bool = { _ in false }
    ) throws -> Harness {
        makeHarness(dbWriter: try AppDatabase.makeInMemory().writer, isRacePinned: isRacePinned)
    }

    private func storedTags(_ dbWriter: any DatabaseWriter, raceId: Int) async throws -> [MemberTag] {
        try await dbWriter.read { db in
            try MemberTag.fetchAll(db, sql: "SELECT * FROM member_tags WHERE raceId = ? ORDER BY number, nfcUid", arguments: [raceId])
        }
    }

    private func seedTag(_ store: MemberTagStore, raceId: Int, nfcUid: String, number: Int) async throws {
        try await store.insertAll([MemberTag(raceId: raceId, nfcUid: nfcUid, number: number)])
    }

    // MARK: - Зеркало MemberTagsRepositoryTest.kt

    @Test func success_mapsEntitiesAndStoresEtag() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(
            statusCode: 200, headers: ["ETag": "\"v1\""],
            bodyString: memberTagsJson([(101, "04A2B3C4D5E680"), (102, "0411223344")])
        )

        #expect(try await h.repo.refreshMemberTags(8) == .updated)

        let tags = try await storedTags(h.dbWriter, raceId: 8)
        #expect(tags.count == 2)
        let tag = tags.first { $0.nfcUid == "04A2B3C4D5E680" }!
        #expect(tag.number == 101)
        #expect(tag.raceId == 8)

        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/member_tags") == "\"v1\"")
    }

    @Test func success_writesDataBeforeEtag() async throws {
        let trace = TraceLog()
        var config = Configuration()
        config.prepareDatabase { db in
            db.trace { trace.append("\($0)") }
        }
        let dbWriter = try AppDatabase(try DatabaseQueue(configuration: config)).writer
        let h = makeHarness(dbWriter: dbWriter)
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: memberTagsJson())

        trace.reset()
        _ = try await h.repo.refreshMemberTags(8)

        #expect(callSequenceMemberTags(trace.lines) == ["deleteEtag", "deleteEtag", "replaceAllForRace", "upsertEtag"])
    }

    @Test func success_withoutEtag_storesTagsAndWritesSyncMarker() async throws {
        let trace = TraceLog()
        var config = Configuration()
        config.prepareDatabase { db in
            db.trace { trace.append("\($0)") }
        }
        let dbWriter = try AppDatabase(try DatabaseQueue(configuration: config)).writer
        let h = makeHarness(dbWriter: dbWriter)
        h.cloudTransport.enqueue(statusCode: 200, bodyString: memberTagsJson())

        trace.reset()
        #expect(try await h.repo.refreshMemberTags(8) == .updated)

        #expect(try await storedTags(h.dbWriter, raceId: 8).count == 1)
        // ETag-ресурс остаётся nil (сервер не прислал ETag), но synced-маркер записан.
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/member_tags") == nil)
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/member_tags/synced") != nil)
        #expect(callSequenceMemberTags(trace.lines) == ["deleteEtag", "deleteEtag", "replaceAllForRace", "upsertEtag"])
    }

    @Test func notModified_leavesDataUntouched() async throws {
        let h = try makeHarness()
        try await seedTag(h.memberTagStore, raceId: 8, nfcUid: "AABB", number: 99)
        try await h.syncMetaStore.upsert(SyncMeta(origin: cloudOrigin, resource: "race/8/member_tags", etag: "\"v1\""))
        h.cloudTransport.enqueue(statusCode: 304)

        #expect(try await h.repo.refreshMemberTags(8) == .notModified)

        #expect(try await storedTags(h.dbWriter, raceId: 8).count == 1)
    }

    @Test func offline_returnsOfflineAndLeavesDataUntouched() async throws {
        let h = try makeHarness()
        try await seedTag(h.memberTagStore, raceId: 8, nfcUid: "AABB", number: 99)
        try await h.syncMetaStore.upsert(SyncMeta(origin: cloudOrigin, resource: "race/8/member_tags", etag: "\"existing\""))
        h.cloudTransport.enqueueError(URLError(.notConnectedToInternet))

        #expect(try await h.repo.refreshMemberTags(8) == .offline)

        #expect(try await storedTags(h.dbWriter, raceId: 8).count == 1)
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/member_tags") == "\"existing\"")
    }

    @Test func forbidden_returnsForbidden() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 403)

        #expect(try await h.repo.refreshMemberTags(8) == .forbidden)
        #expect(try await h.repo.hasBeenSynced(raceId: 8) == false)
    }

    @Test func serverError_returnsHttpError() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 500)

        #expect(try await h.repo.refreshMemberTags(8) == .httpError(500))
        #expect(try await h.repo.hasBeenSynced(raceId: 8) == false)
    }

    @Test func emptyList_replacesExistingRows() async throws {
        let h = try makeHarness()
        try await seedTag(h.memberTagStore, raceId: 8, nfcUid: "AABB", number: 55)
        h.cloudTransport.enqueue(statusCode: 200, bodyString: #"{"member_tags":[]}"#)

        #expect(try await h.repo.refreshMemberTags(8) == .updated)

        #expect(try await storedTags(h.dbWriter, raceId: 8).isEmpty)
    }

    @Test func hasBeenSynced_falseBeforeFirstSync() async throws {
        let h = try makeHarness()
        #expect(try await h.repo.hasBeenSynced(raceId: 8) == false)
    }

    @Test func hasBeenSynced_trueAfterSuccessfulSyncWithEtag() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: memberTagsJson())
        _ = try await h.repo.refreshMemberTags(8)
        #expect(try await h.repo.hasBeenSynced(raceId: 8) == true)
    }

    @Test func hasBeenSynced_trueAfterSuccessfulSyncWithoutEtag() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200, bodyString: memberTagsJson())
        _ = try await h.repo.refreshMemberTags(8)
        // Валидный 200 без ETag всё равно помечает пул синхронизированным через synced-маркер.
        #expect(try await h.repo.hasBeenSynced(raceId: 8) == true)
    }

    @Test func hasBeenSynced_trueAfterNotModified() async throws {
        let h = try makeHarness()
        try await h.syncMetaStore.upsert(SyncMeta(origin: cloudOrigin, resource: "race/8/member_tags", etag: "\"v1\""))
        h.cloudTransport.enqueue(statusCode: 304)
        _ = try await h.repo.refreshMemberTags(8)
        #expect(try await h.repo.hasBeenSynced(raceId: 8) == true)
    }

    @Test func hasBeenSynced_scoped_toRace() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"a\""], bodyString: memberTagsJson())
        _ = try await h.repo.refreshMemberTags(8)
        #expect(try await h.repo.hasBeenSynced(raceId: 8) == true)
        #expect(try await h.repo.hasBeenSynced(raceId: 9) == false)
    }

    @Test func hasBeenSynced_local_readsLocalOriginNotCloud() async throws {
        let h = try makeHarness(isRacePinned: { _ in true })
        h.localTransport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: memberTagsJson())
        _ = try await h.repo.refreshMemberTags(8, source: .local)

        #expect(try await h.repo.hasBeenSynced(raceId: 8, source: .local) == true)
        #expect(try await h.repo.hasBeenSynced(raceId: 8, source: .cloud) == false)
    }

    @Test func observeHasBeenSynced_falseBeforeFirstSync() async throws {
        let h = try makeHarness()
        #expect(try await firstValue(h.repo.observeHasBeenSynced(raceId: 8)) == false)
    }

    @Test func observeHasBeenSynced_trueAfterSuccessfulSyncWithEtag() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: memberTagsJson())
        _ = try await h.repo.refreshMemberTags(8)
        #expect(try await firstValue(h.repo.observeHasBeenSynced(raceId: 8)) == true)
    }

    @Test func observeHasBeenSynced_trueAfterSuccessfulSyncWithoutEtag() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200, bodyString: memberTagsJson())
        _ = try await h.repo.refreshMemberTags(8)
        #expect(try await firstValue(h.repo.observeHasBeenSynced(raceId: 8)) == true)
    }

    @Test func observeHasBeenSynced_scoped_toRace() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"a\""], bodyString: memberTagsJson())
        _ = try await h.repo.refreshMemberTags(8)
        #expect(try await firstValue(h.repo.observeHasBeenSynced(raceId: 8)) == true)
        #expect(try await firstValue(h.repo.observeHasBeenSynced(raceId: 9)) == false)
    }

    @Test func observeHasBeenSynced_local_readsLocalOriginNotCloud() async throws {
        let h = try makeHarness(isRacePinned: { _ in true })
        h.localTransport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: memberTagsJson())
        _ = try await h.repo.refreshMemberTags(8, source: .local)

        #expect(try await firstValue(h.repo.observeHasBeenSynced(raceId: 8, source: .local)) == true)
        #expect(try await firstValue(h.repo.observeHasBeenSynced(raceId: 8, source: .cloud)) == false)
    }

    @Test func observeHasBeenSynced_emitsOnFetchCompletingAfterSubscriptionStarts() async throws {
        // Регрессия на баг, ради которого этот observation введён: коллектор, начавший наблюдать до
        // завершения фетча, должен увидеть переход в `true` на той же подписке, без пере-подписки.
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: memberTagsJson())

        var iterator = h.repo.observeHasBeenSynced(raceId: 8).makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first == false)

        _ = try await h.repo.refreshMemberTags(8)

        var latest = first
        for _ in 0..<8 {
            latest = try await iterator.next()
            if latest == true { break }
        }
        #expect(latest == true)
    }

    @Test func findByUid_resolvesAgainstThatRacePool() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200, bodyString: memberTagsJson([(101, "04A2B3C4D5E680")]))
        _ = try await h.repo.refreshMemberTags(8)

        #expect(try await h.repo.findByUid(raceId: 8, nfcUid: "04A2B3C4D5E680")?.number == 101)
        #expect(try await h.repo.findByUid(raceId: 8, nfcUid: "DEADBEEF") == nil)
        #expect(try await h.repo.findByUid(raceId: 9, nfcUid: "04A2B3C4D5E680") == nil)
    }

    @Test func localSource_hitsLocalClientAndStoresEtagUnderLocalOrigin() async throws {
        let h = try makeHarness(isRacePinned: { _ in true })
        h.localTransport.enqueue(statusCode: 200, headers: ["ETag": "\"local-v1\""], bodyString: memberTagsJson())

        #expect(try await h.repo.refreshMemberTags(8, source: .local) == .updated)

        #expect(try await storedTags(h.dbWriter, raceId: 8).count == 1)
        #expect(try await h.syncMetaStore.getEtag(origin: localOrigin, resource: "race/8/member_tags") == "\"local-v1\"")
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/member_tags") == nil)
        #expect(h.cloudTransport.callCount == 0)
        #expect(h.localTransport.callCount == 1)
    }

    @Test func localSource_invalidatesStaleCloudEtag() async throws {
        let h = try makeHarness(isRacePinned: { _ in true })
        try await h.syncMetaStore.upsert(SyncMeta(origin: cloudOrigin, resource: "race/8/member_tags", etag: "\"cloud-v1\""))
        h.localTransport.enqueue(statusCode: 200, headers: ["ETag": "\"local-v1\""], bodyString: memberTagsJson())

        #expect(try await h.repo.refreshMemberTags(8, source: .local) == .updated)

        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/member_tags") == nil)
        #expect(try await h.syncMetaStore.getEtag(origin: localOrigin, resource: "race/8/member_tags") == "\"local-v1\"")
    }

    @Test func cloudSource_invalidatesStaleLocalEtag() async throws {
        let h = try makeHarness()
        try await h.syncMetaStore.upsert(SyncMeta(origin: localOrigin, resource: "race/8/member_tags", etag: "\"local-v1\""))
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: memberTagsJson())

        #expect(try await h.repo.refreshMemberTags(8) == .updated)

        #expect(try await h.syncMetaStore.getEtag(origin: localOrigin, resource: "race/8/member_tags") == nil)
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/member_tags") == "\"v1\"")
    }

    @Test func localSource_invalidatesStaleCloudSyncMarker() async throws {
        // Прежний cloud-фетч синкнул пустой пул без ETag (только маркер). Переключение на Local и
        // перезапись общей таблицы должны инвалидировать этот маркер.
        let h = try makeHarness(isRacePinned: { _ in true })
        try await h.syncMetaStore.upsert(SyncMeta(origin: cloudOrigin, resource: "race/8/member_tags/synced", etag: "1"))
        h.localTransport.enqueue(statusCode: 200, headers: ["ETag": "\"local-v1\""], bodyString: memberTagsJson())

        #expect(try await h.repo.refreshMemberTags(8, source: .local) == .updated)

        #expect(try await h.repo.hasBeenSynced(raceId: 8, source: .cloud) == false)
    }

    @Test func cloudSource_invalidatesStaleLocalSyncMarker() async throws {
        let h = try makeHarness()
        try await h.syncMetaStore.upsert(SyncMeta(origin: localOrigin, resource: "race/8/member_tags/synced", etag: "1"))
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: memberTagsJson())

        #expect(try await h.repo.refreshMemberTags(8) == .updated)

        #expect(try await h.repo.hasBeenSynced(raceId: 8, source: .local) == false)
    }

    @Test func localSource_unpinnedRace_skipsWithoutTouchingNetworkOrData() async throws {
        let h = try makeHarness(isRacePinned: { _ in false })
        try await seedTag(h.memberTagStore, raceId: 8, nfcUid: "AABB", number: 99)

        #expect(try await h.repo.refreshMemberTags(8, source: .local) == .skipped)

        #expect(h.localTransport.callCount == 0)
        #expect(try await storedTags(h.dbWriter, raceId: 8).count == 1)
    }

    @Test func localSource_unpinDisappearingMidFlight_doesNotPersist() async throws {
        let counter = CallCounter()
        let h = try makeHarness(isRacePinned: { _ in counter.next() == 0 })
        h.localTransport.enqueue(statusCode: 200, headers: ["ETag": "\"local-v1\""], bodyString: memberTagsJson())

        #expect(try await h.repo.refreshMemberTags(8, source: .local) == .skipped)

        #expect(try await storedTags(h.dbWriter, raceId: 8).isEmpty)
        #expect(try await h.syncMetaStore.getEtag(origin: localOrigin, resource: "race/8/member_tags") == nil)
    }

    @Test func cloudSource_pinnedRace_skipsWithoutTouchingNetworkOrData() async throws {
        let h = try makeHarness(isRacePinned: { _ in true })
        try await seedTag(h.memberTagStore, raceId: 8, nfcUid: "AABB", number: 99)

        #expect(try await h.repo.refreshMemberTags(8, source: .cloud) == .skipped)

        #expect(h.cloudTransport.callCount == 0)
        #expect(try await storedTags(h.dbWriter, raceId: 8).count == 1)
    }

    @Test func cloudSource_pinAppearingMidFlight_doesNotPersist() async throws {
        let counter = CallCounter()
        let h = try makeHarness(isRacePinned: { _ in counter.next() > 0 })
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: memberTagsJson())

        #expect(try await h.repo.refreshMemberTags(8, source: .cloud) == .skipped)

        #expect(try await storedTags(h.dbWriter, raceId: 8).isEmpty)
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/member_tags") == nil)
    }

    @Test func unpinnedCloud_behaviorUnchanged() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: memberTagsJson())

        #expect(try await h.repo.refreshMemberTags(8, source: .cloud) == .updated)

        #expect(try await storedTags(h.dbWriter, raceId: 8).count == 1)
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/member_tags") == "\"v1\"")
    }

    @Test func differentRaceIds_useDifferentSyncResources() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"a\""], bodyString: memberTagsJson([(101, "AAA")]))
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"b\""], bodyString: memberTagsJson([(201, "BBB")]))

        _ = try await h.repo.refreshMemberTags(8)
        _ = try await h.repo.refreshMemberTags(9)

        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/member_tags") == "\"a\"")
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/9/member_tags") == "\"b\"")
        #expect(try await storedTags(h.dbWriter, raceId: 8).map(\.nfcUid) == ["AAA"])
        #expect(try await storedTags(h.dbWriter, raceId: 9).map(\.nfcUid) == ["BBB"])
        #expect(h.cloudTransport.recorded[0].url!.absoluteString.contains("/app/race/8/member_tags/"))
        #expect(h.cloudTransport.recorded[1].url!.absoluteString.contains("/app/race/9/member_tags/"))
    }
}

/// Собирает исполненные SQL-операторы в маркеры операций репозитория — Swift-аналог callLog'а из
/// фейкового DAO в `MemberTagsRepositoryTest.kt`. Два `DELETE FROM sync_meta` (ETag + synced-маркер
/// другого origin) дают два `deleteEtag`; `DELETE FROM member_tags` → `replaceAllForRace`.
private func callSequenceMemberTags(_ lines: [String]) -> [String] {
    var out: [String] = []
    for line in lines {
        let s = line.lowercased()
        if s.contains("delete from sync_meta") {
            out.append("deleteEtag")
        } else if s.contains("delete from member_tags") {
            out.append("replaceAllForRace")
        } else if s.contains("sync_meta"), s.contains("insert") || s.contains("update") {
            out.append("upsertEtag")
        }
    }
    return out
}
