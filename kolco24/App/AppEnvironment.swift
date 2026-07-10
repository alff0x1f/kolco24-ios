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
    /// Точки GPS-трека (этап 8): наблюдение/дренаж выгрузки. Питает `TrackUploadRepository` (и
    /// `TrackRecorder` задачи 6).
    let trackStore: TrackStore

    // MARK: - Репозитории (этап 3)
    let raceRepository: RaceRepository
    let teamRepository: TeamRepository
    let legendRepository: LegendRepository
    let memberTagsRepository: MemberTagsRepository

    // MARK: - Этап 6 (выгрузка взятий)
    /// Идемпотентный дренаж взятий в обе цели (LAN + облако). Дёргается триггерами `AppModel`
    /// (таймер / смена команды / закрытие скан-оверлея). `cloud`/`local`-клиенты и `installId`
    /// протянуты в граф явно (раньше клиенты потреблялись лишь в `init` sync-репозиториев).
    let markUploadRepository: MarkUploadRepository

    // MARK: - Этап 8 (выгрузка GPS-трека)
    /// Идемпотентный дренаж точек трека в обе цели (LAN + облако). Дёргается теми же триггерами
    /// `AppModel`, что и marks (5-мин таймер / смена команды), плюс live-upload из `TrackRecorder`
    /// (задача 6). Структурный клон `markUploadRepository` без frame-цикла/version-guard.
    let trackUploadRepository: TrackUploadRepository

    // MARK: - Этап 5 (скан-флоу)
    /// Общие доверенные часы: прод — `pair.clock` из `ApiClients.makeDefaultPair()` (раньше терялся),
    /// теперь `ScanModel` семплит его для времени взятия и монотонного окна (Technical Details §8).
    let trustedClock: TrustedClock
    /// One-shot GPS-провайдер анти-фрод-координаты. Прод-реализация (`CoreLocationProvider`) —
    /// задача 6; до неё no-op-заглушка (`nil` → взятие без координаты).
    let locationProvider: any CurrentLocationProvider
    /// Аудио/тактильный фидбек скана. Прод-реализация (`ScanFeedbackPlayer`) — задача 7; до неё
    /// no-op-заглушка (глотает всё).
    let feedback: any ScanFeedbackPlaying

    // MARK: - Этап 7 (фото-отметка)
    /// Дисковые операции фото-кадров, вынесенные в замыкания, чтобы `PhotoModel` оставался тестируемым
    /// без AVFoundation/ImageIO. Прод — над `PhotoStorage` (Application Support); `inMemory` — no-op фейки.
    /// `writeFrame(markId, jpeg) → относительный путь | nil` (битый кадр); `deleteFrame(rel)` — кадр+тумба;
    /// `sweepOrphanPhotoDirs(liveIds)` — стартовый сбор осиротевших каталогов взятий.
    let writeFrame: @Sendable (String, Data) -> String?
    let deleteFrame: @Sendable (String) -> Void
    let sweepOrphanPhotoDirs: @Sendable (Set<String>) -> Void
    /// Резолвер относительного пути кадра (`marks/<markId>/<uuid>.jpg`) в абсолютный файловый URL —
    /// шов чтения кадров во вьюхах (тайл-превью через `UIImage(contentsOfFile:)`, `ShareLink` в
    /// лайтбоксе). Прод — над `PhotoStorage.rootURL`; `inMemory` — `{ _ in nil }` (диска нет).
    /// Держит `import GRDB`/`Photo/` вне вьюх (grep-инвариант): вью получает только замыкание.
    let photoURL: @Sendable (String) -> URL?

    // MARK: - Этап 8 (GPS-трек, платформенный шов)
    /// Фабрика движка записи трека (`TrackEngine`-шов): прод — `CoreLocationTrackEngine` (единственный
    /// `import CoreLocation`), `inMemory` — `NoTrackEngine`-фейк (реальный GPS только на устройстве).
    /// `TrackRecorder` (задача 6) строится из этих замыканий через `AppModel`.
    let makeEngine: @Sendable () -> any TrackEngine
    /// TOCTOU-проверка геодоступа перед стартом записи (чтение `authorizationStatus` с удерживаемого
    /// `CLLocationManager` прод-движка); `inMemory` → `true`.
    let hasLocationAccess: @Sendable () -> Bool
    /// Выдана ли только «примерная» локация (деградация точности в TrackCard, задача 7); `inMemory` → `false`.
    let isReducedAccuracy: @Sendable () -> Bool
    /// Прогрев разрешения «при использовании» при тапе «Начать запись» (первый старт записи из TrackCard,
    /// если пользователь ни разу не открывал скан-оверлей). Прод — `CoreLocationTrackEngine`; `inMemory` → no-op.
    let requestLocationAuthorization: @Sendable () -> Void

    /// - Parameters:
    ///   - cloudOrigin/localOrigin: base URL'ы — ключи-партиции ETag в `sync_meta`.
    private init(
        database: AppDatabase,
        cloud: ApiClient,
        local: ApiClient,
        installId: String,
        cloudOrigin: String,
        localOrigin: String,
        trustedClock: TrustedClock,
        locationProvider: any CurrentLocationProvider,
        feedback: any ScanFeedbackPlaying,
        frameReader: @escaping (String) -> Data? = { _ in nil },
        writeFrame: @escaping @Sendable (String, Data) -> String? = { _, _ in nil },
        deleteFrame: @escaping @Sendable (String) -> Void = { _ in },
        sweepOrphanPhotoDirs: @escaping @Sendable (Set<String>) -> Void = { _ in },
        photoURL: @escaping @Sendable (String) -> URL? = { _ in nil },
        makeEngine: @escaping @Sendable () -> any TrackEngine = { NoTrackEngine() },
        hasLocationAccess: @escaping @Sendable () -> Bool = { true },
        isReducedAccuracy: @escaping @Sendable () -> Bool = { false },
        requestLocationAuthorization: @escaping @Sendable () -> Void = {},
        wallNow: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.database = database
        self.trustedClock = trustedClock
        self.locationProvider = locationProvider
        self.feedback = feedback
        self.writeFrame = writeFrame
        self.deleteFrame = deleteFrame
        self.sweepOrphanPhotoDirs = sweepOrphanPhotoDirs
        self.photoURL = photoURL
        self.makeEngine = makeEngine
        self.hasLocationAccess = hasLocationAccess
        self.isReducedAccuracy = isReducedAccuracy
        self.requestLocationAuthorization = requestLocationAuthorization
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
        trackStore = TrackStore(writer)

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

        // Этап 6: дренаж взятий поверх тех же cloud/local-клиентов + `installId` (провенанс устройства).
        markUploadRepository = MarkUploadRepository(
            markStore: markStore,
            cloud: cloud,
            local: local,
            installId: installId,
            wallNow: wallNow,
            frameReader: frameReader
        )

        // Этап 8: дренаж точек трека поверх тех же cloud/local-клиентов (без installId — трек не
        // несёт source_install_id, зеркало Kotlin-клиента).
        trackUploadRepository = TrackUploadRepository(
            trackStore: trackStore,
            cloud: cloud,
            local: local,
            wallNow: wallNow
        )
    }

    // MARK: - Фабрики

    /// Прод: файловая БД (`AppDatabase.makeShared`) + пара cloud/LAN-клиентов над общим
    /// `TrustedClock`/`InstallId` (`ApiClients.makeDefaultPair`). Origins = base URL'ы из `Secrets`.
    static func makeShared() throws -> AppEnvironment {
        let database = try AppDatabase.makeShared()
        let pair = ApiClients.makeDefaultPair()
        // Прод-чтение кадров с диска для frame-дренажа: `PhotoStorage` под `Application Support`
        // (тот же корень, что `kolco24.db`). `PhotoPaths.decode` уже отфильтровал небезопасные пути
        // до вызова reader'а, так что `absoluteURL` получает только `marks/<id>/<uuid>.jpg`.
        let photoStorage = try PhotoStorage.makeShared()
        // Этап 8: один удерживаемый `CoreLocationTrackEngine` — источник и фиксов (`makeEngine`), и
        // чтений авторизации (`hasLocationAccess`/`isReducedAccuracy` над удерживаемым `CLLocationManager`;
        // одноразовый инстанс в замыкании врал бы `.notDetermined`). Запись держит один движок за раз;
        // `stop()` идемпотентен, `fixes()` рестартует — переиспользование инстанса безопасно.
        let trackEngine = CoreLocationTrackEngine()
        return AppEnvironment(
            database: database,
            cloud: pair.cloud,
            local: pair.local,
            // `makeDefaultPair()` не возвращает installId — берём его из публичного свойства клиента
            // (тот же UUID, что заголовок `X-Install-Id`), см. Context плана.
            installId: pair.cloud.installId,
            cloudOrigin: Secrets.apiBaseURL,
            localOrigin: Secrets.localAPIBaseURL,
            // Раньше `pair.clock` терялся; теперь общий якорь времени живёт в графе.
            trustedClock: pair.clock,
            // One-shot GPS-фикс на момент взятия (задача 6); прод аудио/тактильный фидбек (задача 7).
            locationProvider: CoreLocationProvider(),
            feedback: ScanFeedbackPlayer(),
            frameReader: { rel in try? Data(contentsOf: photoStorage.absoluteURL(relPath: rel)) },
            // Этап 7: дисковые операции фото-кадров над тем же `PhotoStorage`.
            writeFrame: { markId, data in photoStorage.writeDownscaledJpeg(markId: markId, jpegData: data) },
            deleteFrame: { rel in photoStorage.deleteFrame(relPath: rel) },
            sweepOrphanPhotoDirs: { ids in photoStorage.sweepOrphanDirs(liveMarkIds: ids) },
            photoURL: { rel in photoStorage.absoluteURL(relPath: rel) },
            makeEngine: { trackEngine },
            hasLocationAccess: { trackEngine.hasLocationAccess() },
            isReducedAccuracy: { trackEngine.isReducedAccuracy() },
            requestLocationAuthorization: { trackEngine.requestWhenInUseAuthorization() }
        )
    }

    /// Тесты/превью: in-memory БД + одно транспорт-замыкание для обоих клиентов (в этапе 4 бьётся
    /// только cloud — LAN не задействован). Клиенты подписываются фиктивными секретами: подпись не
    /// проверяется фейком, важен лишь `baseURL`, совпадающий с origin-ключом ETag.
    static func inMemory(
        cloudOrigin: String = "https://cloud.test",
        localOrigin: String = "http://local.test",
        transport: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse),
        trustedClock: TrustedClock = AppEnvironment.makeTestClock(),
        locationProvider: any CurrentLocationProvider = NoLocationProvider(),
        feedback: any ScanFeedbackPlaying = SilentFeedback(),
        writeFrame: @escaping @Sendable (String, Data) -> String? = { _, _ in nil },
        deleteFrame: @escaping @Sendable (String) -> Void = { _ in },
        sweepOrphanPhotoDirs: @escaping @Sendable (Set<String>) -> Void = { _ in },
        photoURL: @escaping @Sendable (String) -> URL? = { _ in nil },
        makeEngine: @escaping @Sendable () -> any TrackEngine = { NoTrackEngine() },
        hasLocationAccess: @escaping @Sendable () -> Bool = { true },
        isReducedAccuracy: @escaping @Sendable () -> Bool = { false },
        requestLocationAuthorization: @escaping @Sendable () -> Void = {}
    ) throws -> AppEnvironment {
        let database = try AppDatabase.makeInMemory()
        return AppEnvironment(
            database: database,
            cloud: testClient(baseURL: cloudOrigin, transport: transport),
            local: testClient(baseURL: localOrigin, transport: transport),
            installId: "install-test",
            cloudOrigin: cloudOrigin,
            localOrigin: localOrigin,
            trustedClock: trustedClock,
            locationProvider: locationProvider,
            feedback: feedback,
            writeFrame: writeFrame,
            deleteFrame: deleteFrame,
            sweepOrphanPhotoDirs: sweepOrphanPhotoDirs,
            photoURL: photoURL,
            makeEngine: makeEngine,
            hasLocationAccess: hasLocationAccess,
            isReducedAccuracy: isReducedAccuracy,
            requestLocationAuthorization: requestLocationAuthorization
        )
    }

    /// Дефолтные часы для `inMemory`: фейковые провайдеры (elapsed/wall = 0, boot = nil),
    /// без персистенции. Тесты, которым важно управляемое время, инжектят собственный `TrustedClock`.
    static func makeTestClock() -> TrustedClock {
        TrustedClock(
            elapsedProvider: { 0 },
            wallProvider: { 0 },
            bootCountProvider: { nil }
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

// MARK: - No-op заглушки платформенных швов этапа 5
//
// Держат граф собираемым с задачи 3 (чтобы `ScanModel` задачи 4 строился) до прихода
// прод-реализаций в задачах 6–7. Обе стороны безопасны по контракту: провайдер локации
// «никогда не бросает, `nil` допустим», фидбек — best-effort «любой сбой проглатывается».

/// No-op провайдер локации: всегда `nil` (взятие без координаты). Прод — `CoreLocationProvider` (задача 6).
struct NoLocationProvider: CurrentLocationProvider {
    func current(timeoutMs: Int64) async -> RawFix? { nil }
}

/// No-op фидбек: проглатывает всё. Прод — `ScanFeedbackPlayer` (задача 7).
struct SilentFeedback: ScanFeedbackPlaying {
    func play(_ kind: ScanFeedbackKind) {}
    func fanfare() {}
}

/// No-op движок трека для `inMemory`-графа: стрим ОСТАЁТСЯ открытым (фиксов нет — реальный GPS только
/// на устройстве), завершается лишь на `stop()` — как прод-движок. Иначе мгновенно завершившийся стрим
/// сигналил бы `TrackRecorder` «движок умер» и тут же откатывал запись в `.idle`. Прод —
/// `CoreLocationTrackEngine` (`Location/`).
final class NoTrackEngine: TrackEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<RawFix>.Continuation?

    func fixes() -> AsyncStream<RawFix> {
        AsyncStream { cont in
            lock.lock(); continuation?.finish(); continuation = cont; lock.unlock()
        }
    }

    func stop() {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.finish()
    }
}
