//
//  LegendRepositoryTests.swift
//  kolco24Tests
//
//  Зеркало `data/LegendRepositoryTest.kt` (29 кейсов) поверх РЕАЛЬНЫХ store'ов над
//  `AppDatabase.makeInMemory()` (конвенция этапа 2 — без фейков) + `FakeTransport` (замена
//  `MockWebServer`). Отдельный cloud/local `FakeTransport` играет роль двух `MockWebServer`'ов.
//
//  Refresh-набор (как у `RaceRepositoryTests`/`TeamRepositoryTests`) + маппинг locked/color/tags,
//  персист и дефолты `total_cost`/`scoring_count`, reveal-переживает-resync (preserve-reveal), полная
//  pin-guard-матрица, кросс-origin-инвалидация. Плюс unlock-матрица: reveal+persist, неизвестный bid →
//  unknown, открытый КП → identityOnly, частичный конверт → failed, испорченный шифротекст → failed.
//  Крипто-входы взяты из KAT-вектора `LegendCryptoTests` (этап 1) — server-generated, не свежий seal.
//  Порядок «данные → потом ETag» проверяется трассировкой SQL реальной БД (`Database.trace`).
//

import Foundation
import GRDB
import Testing
@testable import kolco24

struct LegendRepositoryTests {

    private let cloudOrigin = "https://cloud.test"
    private let localOrigin = "http://local.test"

    // region ───────── серверный KAT-вектор (из LegendCryptoTests, этап 1) ─────────
    // code = 00 01 02 ... 0f (16 байт). Два запертых КП через цепочку bundle → content_key → enc.
    private enum Vector {
        static let codeHex = "000102030405060708090a0b0c0d0e0f"
        static let expectedBid = "be45cb2605bf36be"
        static let tagIvB64 = "IvXiSPaYJsMfVBGh"
        static let tagCtB64 =
            "Vft9QueXUG3VYGXVh/GAB45AYvRWitc+tRqjNrandoEpdoFpV3uMqE5P4fuOpKjCUSp6jxuZXdzRG8xZ4j0n10UU1dJB75LtKCCt14lcWkvDnxrmouGByy2vDdIg76Nh8/CDf9KtY1sGZgevklB+JvdGBRGQWC5UyWW2BI+6"
        static let cp1Id = 103
        static let cp1EncIvB64 = "KqObDTP3AZKlMl6f"
        static let cp1EncCtB64 =
            "kQtwDqbS6Yo1+rnzTmdAvbrY6YS/GvWWREFUoCWL9WVn5hvqJul0U8BM1aKGT/NTUlMgyN5ZCIdVp7OY"
        static let cp1Cost = 5
        static let cp1Description = "Вершина"
        static let cp2Id = 207
        static let cp2EncIvB64 = "qrkoluxPBW5ZidNg"
        static let cp2EncCtB64 =
            "QQD2pxGZY19GcRP1mL+NTRiCqte8YfvloCikCQ8e/yin+Y0Fm2hWM9+gZOR+le9EbP5HTTS3vqXelA=="
        static let cp2Cost = 3
        static let cp2Description = "Родник"

        static var code: Data { Data(HexBytes.decode(codeHex)) }
    }
    // endregion

    // MARK: - Фикстуры

    private func legendJson(
        raceId: Int = 8,
        checkpointIds: [Int] = [101],
        totalCost: Int = 10,
        scoringCount: Int? = nil
    ) -> String {
        var s = "{\"race\":\(raceId),\"total_cost\":\(totalCost),"
        if let scoringCount { s += "\"scoring_count\":\(scoringCount)," }
        s += "\"checkpoints\":["
        for (index, id) in checkpointIds.enumerated() {
            if index > 0 { s += "," }
            s += "{\"id\":\(id),\"number\":\(index + 1),\"cost\":10,\"type\":\"kp\",\"description\":\"КП \(id)\"}"
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
        let repo: LegendRepository
        let dbWriter: any DatabaseWriter
        let checkpointStore: CheckpointStore
        let tagStore: TagStore
        let legendMetaStore: LegendMetaStore
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
        let checkpointStore = CheckpointStore(dbWriter)
        let tagStore = TagStore(dbWriter)
        let legendMetaStore = LegendMetaStore(dbWriter)
        let syncMetaStore = SyncMetaStore(dbWriter)
        let repo = LegendRepository(
            apiClient: makeApiClient(baseURL: cloudOrigin, transport: cloudTransport),
            checkpointStore: checkpointStore,
            tagStore: tagStore,
            legendMetaStore: legendMetaStore,
            syncMetaStore: syncMetaStore,
            origin: cloudOrigin,
            localApiClient: makeApiClient(baseURL: localOrigin, transport: localTransport),
            localOrigin: localOrigin,
            isRacePinned: isRacePinned
        )
        return Harness(
            repo: repo,
            dbWriter: dbWriter,
            checkpointStore: checkpointStore,
            tagStore: tagStore,
            legendMetaStore: legendMetaStore,
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

    private func storedCheckpoints(_ dbWriter: any DatabaseWriter, raceId: Int) async throws -> [Checkpoint] {
        try await dbWriter.read { db in
            try Checkpoint.fetchAll(
                db,
                sql: "SELECT * FROM checkpoints WHERE raceId = ? ORDER BY number, id",
                arguments: [raceId]
            )
        }
    }

    private func storedTags(_ dbWriter: any DatabaseWriter, raceId: Int) async throws -> [kolco24.Tag] {
        try await dbWriter.read { db in
            try kolco24.Tag.fetchAll(db, sql: "SELECT * FROM tags WHERE raceId = ? ORDER BY checkpointId, bid", arguments: [raceId])
        }
    }

    private func seedCheckpoint(_ store: CheckpointStore, id: Int, raceId: Int) async throws {
        try await store.insertCheckpoints([
            Checkpoint(id: id, raceId: raceId, number: 1, cost: 10, type: "kp", description: "test"),
        ])
    }

    private func seedLockedCheckpoint(_ store: CheckpointStore, id: Int, raceId: Int, encIv: String, encCt: String) async throws {
        try await store.insertCheckpoints([
            Checkpoint(id: id, raceId: raceId, number: 1, cost: nil, type: "kp", description: nil,
                       locked: true, encIv: encIv, encCt: encCt),
        ])
    }

    // MARK: - Зеркало LegendRepositoryTest.kt

    @Test func success_mapsEntitiesAndStoresEtag() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""],
                                 bodyString: legendJson(checkpointIds: [101, 102]))

        #expect(try await h.repo.refreshLegend(8) == .updated)

        let checkpoints = try await storedCheckpoints(h.dbWriter, raceId: 8)
        #expect(checkpoints.count == 2)
        let cp = checkpoints[0]
        #expect(cp.id == 101)
        #expect(cp.raceId == 8)
        #expect(cp.number == 1)
        #expect(cp.cost == 10)
        #expect(cp.type == "kp")
        #expect(cp.color == "")

        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/legend") == "\"v1\"")
    }

    @Test func success_mapsColorToEntity() async throws {
        let h = try makeHarness()
        let payload = """
        {"race":8,"checkpoints":[
            {"id":101,"number":1,"cost":10,"type":"kp","description":"A","color":"blue"},
            {"id":102,"number":2,"cost":5,"type":"kp","description":"B"}
        ]}
        """
        h.cloudTransport.enqueue(statusCode: 200, bodyString: payload)

        _ = try await h.repo.refreshLegend(8)

        let checkpoints = try await storedCheckpoints(h.dbWriter, raceId: 8)
        #expect(checkpoints.first { $0.id == 101 }?.color == "blue")
        #expect(checkpoints.first { $0.id == 102 }?.color == "")
    }

    @Test func success_writesDataBeforeEtag() async throws {
        let trace = TraceLog()
        var config = Configuration()
        config.prepareDatabase { db in
            db.trace { trace.append("\($0)") }
        }
        let dbWriter = try AppDatabase(try DatabaseQueue(configuration: config)).writer
        let h = makeHarness(dbWriter: dbWriter)
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: legendJson())

        trace.reset() // отбросить трассы миграций
        _ = try await h.repo.refreshLegend(8)

        #expect(callSequenceLegend(trace.lines) ==
            ["deleteEtag", "replaceAllForRace", "replaceAllTags", "upsertLegendMeta", "upsertEtag"])
    }

    @Test func success_withoutEtag_storesCheckpointsButSkipsEtagSave() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200, bodyString: legendJson())

        #expect(try await h.repo.refreshLegend(8) == .updated)

        #expect(try await storedCheckpoints(h.dbWriter, raceId: 8).count == 1)
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/legend") == nil)
    }

    @Test func success_persistsTotalCost() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200,
                                 bodyString: legendJson(checkpointIds: [101, 102], totalCost: 42))

        _ = try await h.repo.refreshLegend(8)

        #expect(try await firstValue(h.repo.totalCostForRace(8)) == 42)
    }

    @Test func totalCost_defaultsToZeroBeforeSync() async throws {
        let h = try makeHarness()
        #expect(try await firstValue(h.repo.totalCostForRace(8)) == 0)
    }

    @Test func success_persistsScoringCount() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200,
                                 bodyString: legendJson(checkpointIds: [101, 102], scoringCount: 7))

        _ = try await h.repo.refreshLegend(8)

        #expect(try await firstValue(h.repo.scoringCountForRace(8)) == 7)
    }

    @Test func scoringCount_missingFromResponse_defaultsToZero() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200, bodyString: legendJson())

        _ = try await h.repo.refreshLegend(8)

        #expect(try await firstValue(h.repo.scoringCountForRace(8)) == 0)
    }

    @Test func scoringCount_defaultsToZeroBeforeSync() async throws {
        let h = try makeHarness()
        #expect(try await firstValue(h.repo.scoringCountForRace(8)) == 0)
    }

    @Test func notModified_leavesDataUntouched() async throws {
        let h = try makeHarness()
        try await seedCheckpoint(h.checkpointStore, id: 99, raceId: 8)
        try await h.syncMetaStore.upsert(SyncMeta(origin: cloudOrigin, resource: "race/8/legend", etag: "\"v1\""))
        h.cloudTransport.enqueue(statusCode: 304)

        #expect(try await h.repo.refreshLegend(8) == .notModified)

        let checkpoints = try await storedCheckpoints(h.dbWriter, raceId: 8)
        #expect(checkpoints.count == 1)
        #expect(checkpoints[0].id == 99)
    }

    @Test func offline_returnsOfflineAndLeavesDataUntouched() async throws {
        let h = try makeHarness()
        try await seedCheckpoint(h.checkpointStore, id: 99, raceId: 8)
        try await h.syncMetaStore.upsert(SyncMeta(origin: cloudOrigin, resource: "race/8/legend", etag: "\"existing\""))
        h.cloudTransport.enqueueError(URLError(.notConnectedToInternet))

        #expect(try await h.repo.refreshLegend(8) == .offline)

        #expect(try await storedCheckpoints(h.dbWriter, raceId: 8).count == 1)
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/legend") == "\"existing\"")
    }

    @Test func forbidden_returnsForbidden() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 403)

        #expect(try await h.repo.refreshLegend(8) == .forbidden)
    }

    @Test func serverError_returnsHttpError() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 500)

        #expect(try await h.repo.refreshLegend(8) == .httpError(500))
    }

    @Test func differentRaceIds_useDifferentSyncResources() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"a\""], bodyString: legendJson(raceId: 8))
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"b\""],
                                 bodyString: legendJson(raceId: 9, checkpointIds: [201]))

        _ = try await h.repo.refreshLegend(8)
        _ = try await h.repo.refreshLegend(9)

        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/legend") == "\"a\"")
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/9/legend") == "\"b\"")
        #expect(h.cloudTransport.recorded[0].url!.absoluteString.contains("/app/race/8/legend/"))
        #expect(h.cloudTransport.recorded[1].url!.absoluteString.contains("/app/race/9/legend/"))
    }

    @Test func emptyCheckpoints_replacesExistingRows() async throws {
        let h = try makeHarness()
        try await seedCheckpoint(h.checkpointStore, id: 55, raceId: 8)
        h.cloudTransport.enqueue(statusCode: 200, bodyString: "{\"race\":8,\"checkpoints\":[]}")

        #expect(try await h.repo.refreshLegend(8) == .updated)

        #expect(try await storedCheckpoints(h.dbWriter, raceId: 8).isEmpty)
    }

    @Test func success_mapsLockedCheckpointAndTags() async throws {
        let h = try makeHarness()
        let body = """
        {"race":8,"checkpoints":[
          {"id":101,"number":1,"cost":10,"type":"kp","description":"open"},
          {"id":102,"number":2,"type":"kp","enc":{"iv":"AAAA","ct":"BBBB"}}
        ],"tags":[
          {"bid":"abc123","checkpoint_id":101,"check_method":"nfc"},
          {"bid":"def456","checkpoint_id":102,"check_method":"nfc","iv":"IV","ct":"CT"}
        ]}
        """
        h.cloudTransport.enqueue(statusCode: 200, bodyString: body)

        #expect(try await h.repo.refreshLegend(8) == .updated)

        let checkpoints = try await storedCheckpoints(h.dbWriter, raceId: 8)
        let locked = try #require(checkpoints.first { $0.id == 102 })
        #expect(locked.locked)
        #expect(locked.cost == nil)
        #expect(locked.description == nil)
        #expect(locked.encIv == "AAAA")
        #expect(locked.encCt == "BBBB")
        let open = try #require(checkpoints.first { $0.id == 101 })
        #expect(!open.locked)
        #expect(open.cost == 10)

        let tags = try await storedTags(h.dbWriter, raceId: 8)
        #expect(tags.count == 2)
        #expect(tags.first { $0.bid == "abc123" }?.iv == nil)
        #expect(tags.first { $0.bid == "def456" }?.iv == "IV")
    }

    /// БОНУС-семантика: preserve-reveal переживает resync. В Kotlin поведение preserve-reveal
    /// проверяется в `CheckpointDaoTest`; здесь — сквозная проверка через репозиторий (реальный
    /// `replaceAllForRace`, не фейк). Раскрытый оффлайн КП не залочивается снова после `200`.
    @Test func refresh_preservesOfflineRevealAcrossResync() async throws {
        let h = try makeHarness()
        // Первый синк с запертым КП 102 (enc-конверт).
        h.cloudTransport.enqueue(statusCode: 200, bodyString: """
        {"race":8,"checkpoints":[{"id":102,"number":1,"type":"kp","enc":{"iv":"AAAA","ct":"BBBB"}}]}
        """)
        _ = try await h.repo.refreshLegend(8)
        // Оффлайн-раскрытие КП 102.
        try await h.checkpointStore.reveal(id: 102, cost: 9, description: "Раскрыто")
        // Второй синк присылает КП 102 всё ещё запертым.
        h.cloudTransport.enqueue(statusCode: 200, bodyString: """
        {"race":8,"checkpoints":[{"id":102,"number":1,"type":"kp","enc":{"iv":"AAAA","ct":"BBBB"}}]}
        """)
        _ = try await h.repo.refreshLegend(8)

        let cp = try #require(try await storedCheckpoints(h.dbWriter, raceId: 8).first { $0.id == 102 })
        #expect(cp.cost == 9)
        #expect(cp.description == "Раскрыто")
        #expect(!cp.locked)
    }

    // MARK: - Зеркало LegendRepositoryTest.kt (unlock-матрица)

    @Test func unlock_revealsAndPersistsCheckpointPlaintext() async throws {
        let h = try makeHarness()
        try await seedLockedCheckpoint(h.checkpointStore, id: Vector.cp1Id, raceId: 8,
                                       encIv: Vector.cp1EncIvB64, encCt: Vector.cp1EncCtB64)
        try await seedLockedCheckpoint(h.checkpointStore, id: Vector.cp2Id, raceId: 8,
                                       encIv: Vector.cp2EncIvB64, encCt: Vector.cp2EncCtB64)
        try await h.tagStore.insertTags([
            kolco24.Tag(raceId: 8, bid: Vector.expectedBid, checkpointId: Vector.cp1Id,
                checkMethod: "nfc", iv: Vector.tagIvB64, ct: Vector.tagCtB64),
        ])

        let outcome = try await h.repo.unlock(raceId: 8, code: Vector.code)

        #expect(outcome == .revealed(checkpointId: Vector.cp1Id, checkpointIds: [Vector.cp1Id, Vector.cp2Id]))

        let checkpoints = try await storedCheckpoints(h.dbWriter, raceId: 8)
        let cp1 = try #require(checkpoints.first { $0.id == Vector.cp1Id })
        #expect(cp1.cost == Vector.cp1Cost)
        #expect(cp1.description == Vector.cp1Description)
        #expect(!cp1.locked)
        let cp2 = try #require(checkpoints.first { $0.id == Vector.cp2Id })
        #expect(cp2.cost == Vector.cp2Cost)
        #expect(cp2.description == Vector.cp2Description)
        #expect(!cp2.locked)
    }

    @Test func unlock_unknownBidReturnsUnknown() async throws {
        let h = try makeHarness()
        let outcome = try await h.repo.unlock(raceId: 8, code: Data([UInt8](repeating: 1, count: 16)))
        #expect(outcome == .unknown)
    }

    @Test func unlock_openCpTagReturnsIdentityOnly() async throws {
        let h = try makeHarness()
        let code = Data([UInt8](repeating: 2, count: 16))
        try await h.tagStore.insertTags([
            kolco24.Tag(raceId: 8, bid: LegendCrypto.bid(code: code), checkpointId: 101,
                checkMethod: "nfc", iv: nil, ct: nil),
        ])

        #expect(try await h.repo.unlock(raceId: 8, code: code) == .identityOnly(checkpointId: 101))
    }

    @Test func unlock_partialEnvelopeReturnsFailed() async throws {
        let h = try makeHarness()
        let code = Data([UInt8](repeating: 4, count: 16))
        try await h.tagStore.insertTags([
            kolco24.Tag(raceId: 8, bid: LegendCrypto.bid(code: code), checkpointId: 101,
                checkMethod: "nfc", iv: "someIv", ct: nil),
        ])

        guard case .failed = try await h.repo.unlock(raceId: 8, code: code) else {
            Issue.record("expected .failed")
            return
        }
    }

    @Test func unlock_tamperedCiphertextReturnsFailed() async throws {
        let h = try makeHarness()
        // KAT-тег с испорченным bundle-ct: bid всё ещё совпадает (зависит от code), тег находится,
        // но открытие bundle_blob падает по GCM-тегу → failed.
        let firstChar = Vector.tagCtB64.first!
        let tamperedCt = (firstChar == "A" ? "B" : "A") + Vector.tagCtB64.dropFirst()
        try await seedLockedCheckpoint(h.checkpointStore, id: Vector.cp1Id, raceId: 8,
                                       encIv: Vector.cp1EncIvB64, encCt: Vector.cp1EncCtB64)
        try await h.tagStore.insertTags([
            kolco24.Tag(raceId: 8, bid: Vector.expectedBid, checkpointId: Vector.cp1Id,
                checkMethod: "nfc", iv: Vector.tagIvB64, ct: tamperedCt),
        ])

        guard case .failed = try await h.repo.unlock(raceId: 8, code: Vector.code) else {
            Issue.record("expected .failed")
            return
        }
    }

    // MARK: - Зеркало LegendRepositoryTest.kt (source/pin)

    @Test func localSource_hitsLocalClientAndStoresEtagUnderLocalOrigin() async throws {
        let h = try makeHarness(isRacePinned: { _ in true })
        h.localTransport.enqueue(statusCode: 200, headers: ["ETag": "\"local-v1\""], bodyString: legendJson())

        #expect(try await h.repo.refreshLegend(8, source: .local) == .updated)

        #expect(try await storedCheckpoints(h.dbWriter, raceId: 8).count == 1)
        #expect(try await h.syncMetaStore.getEtag(origin: localOrigin, resource: "race/8/legend") == "\"local-v1\"")
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/legend") == nil)
        #expect(h.cloudTransport.callCount == 0)
        #expect(h.localTransport.callCount == 1)
    }

    @Test func localSource_invalidatesStaleCloudEtag() async throws {
        let h = try makeHarness(isRacePinned: { _ in true })
        try await h.syncMetaStore.upsert(SyncMeta(origin: cloudOrigin, resource: "race/8/legend", etag: "\"cloud-v1\""))
        h.localTransport.enqueue(statusCode: 200, headers: ["ETag": "\"local-v1\""], bodyString: legendJson())

        #expect(try await h.repo.refreshLegend(8, source: .local) == .updated)

        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/legend") == nil)
        #expect(try await h.syncMetaStore.getEtag(origin: localOrigin, resource: "race/8/legend") == "\"local-v1\"")
    }

    @Test func cloudSource_invalidatesStaleLocalEtag() async throws {
        let h = try makeHarness()
        try await h.syncMetaStore.upsert(SyncMeta(origin: localOrigin, resource: "race/8/legend", etag: "\"local-v1\""))
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: legendJson())

        #expect(try await h.repo.refreshLegend(8) == .updated)

        #expect(try await h.syncMetaStore.getEtag(origin: localOrigin, resource: "race/8/legend") == nil)
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/legend") == "\"v1\"")
    }

    @Test func cloudSource_pinnedRace_skipsWithoutTouchingNetworkOrData() async throws {
        let h = try makeHarness(isRacePinned: { _ in true })
        try await seedCheckpoint(h.checkpointStore, id: 99, raceId: 8)

        #expect(try await h.repo.refreshLegend(8, source: .cloud) == .skipped)

        #expect(h.cloudTransport.callCount == 0)
        #expect(try await storedCheckpoints(h.dbWriter, raceId: 8).count == 1)
    }

    @Test func cloudSource_pinAppearingMidFlight_doesNotPersist() async throws {
        // false на входном guard'е, true на пред-персист-повторе — пин «прилетел» в полёте.
        let counter = CallCounter()
        let h = try makeHarness(isRacePinned: { _ in counter.next() > 0 })
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: legendJson())

        #expect(try await h.repo.refreshLegend(8, source: .cloud) == .skipped)

        #expect(try await storedCheckpoints(h.dbWriter, raceId: 8).isEmpty)
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/legend") == nil)
    }

    @Test func localSource_unpinnedRace_skipsWithoutTouchingNetworkOrData() async throws {
        let h = try makeHarness(isRacePinned: { _ in false })
        try await seedCheckpoint(h.checkpointStore, id: 99, raceId: 8)

        #expect(try await h.repo.refreshLegend(8, source: .local) == .skipped)

        #expect(h.localTransport.callCount == 0)
        #expect(try await storedCheckpoints(h.dbWriter, raceId: 8).count == 1)
    }

    @Test func localSource_unpinDisappearingMidFlight_doesNotPersist() async throws {
        // true на входном guard'е, false на пред-персист-повторе — LAN выключили в полёте.
        let counter = CallCounter()
        let h = try makeHarness(isRacePinned: { _ in counter.next() == 0 })
        h.localTransport.enqueue(statusCode: 200, headers: ["ETag": "\"local-v1\""], bodyString: legendJson())

        #expect(try await h.repo.refreshLegend(8, source: .local) == .skipped)

        #expect(try await storedCheckpoints(h.dbWriter, raceId: 8).isEmpty)
        #expect(try await h.syncMetaStore.getEtag(origin: localOrigin, resource: "race/8/legend") == nil)
    }

    @Test func unpinnedCloud_behaviorUnchanged() async throws {
        let h = try makeHarness()
        h.cloudTransport.enqueue(statusCode: 200, headers: ["ETag": "\"v1\""], bodyString: legendJson())

        #expect(try await h.repo.refreshLegend(8, source: .cloud) == .updated)

        #expect(try await storedCheckpoints(h.dbWriter, raceId: 8).count == 1)
        #expect(try await h.syncMetaStore.getEtag(origin: cloudOrigin, resource: "race/8/legend") == "\"v1\"")
    }
}

/// Собирает исполненные SQL-операторы в маркеры операций репозитория — Swift-аналог callLog'а из
/// фейковых DAO в `LegendRepositoryTest.kt`. `replaceAllForRace`/`replaceAllTags` матчатся по
/// `DELETE FROM checkpoints`/`DELETE FROM tags` (селекты/вставки/апдейты preserve-reveal дают один
/// маркер каждый).
private func callSequenceLegend(_ lines: [String]) -> [String] {
    var out: [String] = []
    for line in lines {
        let s = line.lowercased()
        if s.contains("delete from sync_meta") {
            out.append("deleteEtag")
        } else if s.contains("delete from checkpoints") {
            out.append("replaceAllForRace")
        } else if s.contains("delete from tags") {
            out.append("replaceAllTags")
        } else if s.contains("legend_meta"), s.contains("insert") || s.contains("update") {
            out.append("upsertLegendMeta")
        } else if s.contains("sync_meta"), s.contains("insert") || s.contains("update") {
            out.append("upsertEtag")
        }
    }
    return out
}
