//
//  AppEnvironment.swift
//  kolco24
//
//  Composition root приложения — аналог `AppContainer.kt` (только та часть, что нужна этапу 4:
//  БД + сеть + сторы + 4 sync-репозитория). Не 1в1 из Kotlin: у Android `AppContainer` тянет ещё
//  трек/фото/lease/admin-слои (этапы 5–10) — здесь только то, что подключает существующий UI к данным.
//
//  Обычный `final class` (не `@Observable`, не `@MainActor`): держит неизменяемый граф зависимостей,
//  создаётся один раз в `kolco24App`. Реактивное состояние живёт в `AppModel` и per-tab моделях.
//
//  Два инициализатора: прод (`makeShared` — файловая БД + `ApiClients.makeDefaultPair`) и `inMemory`
//  (in-memory БД + инъекция транспорт-замыкания — для тестов и превью, по конвенции этапа 3, где
//  `FakeTransport.handle` подставляется прямо в `ApiClient.transport`).
//
//  `App/` — не под `Data/`, но `import GRDB` здесь не нужен: типы GRDB (`any DatabaseWriter`) проходят
//  через `database.writer` без явного упоминания (grep-инвариант: `import GRDB` только под `Data/`).
//

import Foundation

/// Неизменяемый граф зависимостей приложения: БД, сторы, репозитории. Источник всегда `.cloud`
/// (LAN/lease — этап 9), поэтому `isRacePinned` у всех pin-guard-репозиториев зашит в `false`.
final class AppEnvironment {

    let database: AppDatabase

    // MARK: - Сторы (этап 2)
    let raceStore: RaceStore
    let teamStore: TeamStore
    let selectedTeamStore: SelectedTeamStore
    let checkpointStore: CheckpointStore
    let markStore: MarkStore
    let legendMetaStore: LegendMetaStore
    let tagStore: TagStore
    let memberTagStore: MemberTagStore
    /// Привязки чипов дёргаются напрямую (без репозитория-обёртки — YAGNI, Android-обёртка тривиальна).
    let memberChipBindingStore: MemberChipBindingStore
    let syncMetaStore: SyncMetaStore

    // MARK: - Репозитории (этап 3)
    let raceRepository: RaceRepository
    let teamRepository: TeamRepository
    let legendRepository: LegendRepository
    let memberTagsRepository: MemberTagsRepository

    /// - Parameters:
    ///   - cloudOrigin/localOrigin: base URL'ы — ключи-партиции ETag в `sync_meta`.
    private init(
        database: AppDatabase,
        cloud: ApiClient,
        local: ApiClient,
        cloudOrigin: String,
        localOrigin: String
    ) {
        self.database = database
        let writer = database.writer

        raceStore = RaceStore(writer)
        teamStore = TeamStore(writer)
        selectedTeamStore = SelectedTeamStore(writer)
        checkpointStore = CheckpointStore(writer)
        markStore = MarkStore(writer)
        legendMetaStore = LegendMetaStore(writer)
        tagStore = TagStore(writer)
        memberTagStore = MemberTagStore(writer)
        memberChipBindingStore = MemberChipBindingStore(writer)
        syncMetaStore = SyncMetaStore(writer)

        // Этап 4: источник всегда cloud, гонки не пришпилены к LAN.
        let notPinned: (Int) -> Bool = { _ in false }

        raceRepository = RaceRepository(
            apiClient: cloud,
            raceStore: raceStore,
            syncMetaStore: syncMetaStore,
            origin: cloudOrigin,
            localApiClient: local,
            localOrigin: localOrigin
        )
        teamRepository = TeamRepository(
            apiClient: cloud,
            teamStore: teamStore,
            selectedTeamStore: selectedTeamStore,
            syncMetaStore: syncMetaStore,
            origin: cloudOrigin,
            localApiClient: local,
            localOrigin: localOrigin,
            isRacePinned: notPinned
        )
        legendRepository = LegendRepository(
            apiClient: cloud,
            checkpointStore: checkpointStore,
            tagStore: tagStore,
            legendMetaStore: legendMetaStore,
            syncMetaStore: syncMetaStore,
            origin: cloudOrigin,
            localApiClient: local,
            localOrigin: localOrigin,
            isRacePinned: notPinned
        )
        memberTagsRepository = MemberTagsRepository(
            apiClient: cloud,
            memberTagStore: memberTagStore,
            syncMetaStore: syncMetaStore,
            origin: cloudOrigin,
            localApiClient: local,
            localOrigin: localOrigin,
            isRacePinned: notPinned
        )
    }

    // MARK: - Фабрики

    /// Прод: файловая БД (`AppDatabase.makeShared`) + пара cloud/LAN-клиентов над общим
    /// `TrustedClock`/`InstallId` (`ApiClients.makeDefaultPair`). Origins = base URL'ы из `Secrets`.
    static func makeShared() throws -> AppEnvironment {
        let database = try AppDatabase.makeShared()
        let pair = ApiClients.makeDefaultPair()
        return AppEnvironment(
            database: database,
            cloud: pair.cloud,
            local: pair.local,
            cloudOrigin: Secrets.apiBaseURL,
            localOrigin: Secrets.localAPIBaseURL
        )
    }

    /// Тесты/превью: in-memory БД + одно транспорт-замыкание для обоих клиентов (в этапе 4 бьётся
    /// только cloud — LAN не задействован). Клиенты подписываются фиктивными секретами: подпись не
    /// проверяется фейком, важен лишь `baseURL`, совпадающий с origin-ключом ETag.
    static func inMemory(
        cloudOrigin: String = "https://cloud.test",
        localOrigin: String = "http://local.test",
        transport: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) throws -> AppEnvironment {
        let database = try AppDatabase.makeInMemory()
        return AppEnvironment(
            database: database,
            cloud: testClient(baseURL: cloudOrigin, transport: transport),
            local: testClient(baseURL: localOrigin, transport: transport),
            cloudOrigin: cloudOrigin,
            localOrigin: localOrigin
        )
    }

    private static func testClient(
        baseURL: String,
        transport: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) -> ApiClient {
        ApiClient(
            baseURL: baseURL,
            keyId: "ios-test",
            secret: "test-secret",
            installId: "install-test",
            appVersion: "test",
            nowSeconds: { 0 },
            elapsedNowMs: { 0 },
            onServerTime: nil,
            tokenProvider: { nil },
            transport: transport
        )
    }
}
