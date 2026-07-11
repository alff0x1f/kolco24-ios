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

    /// UUID устройства (тот же, что заголовок `X-Install-Id`): `source_install_id` тела судейского
    /// пика (этап 10, `JudgeScanModel`) и провенанс дренажей выгрузки.
    let installId: String

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
    /// Судейские пики старта/финиша (этап 10): наблюдение/дренаж выгрузки. Питает
    /// `JudgeScanUploadRepository` (и `JudgeScanModel` задачи 8).
    let judgeScanStore: JudgeScanStore

    // MARK: - Репозитории (этап 3)
    let raceRepository: RaceRepository
    let teamRepository: TeamRepository
    let legendRepository: LegendRepository
    let memberTagsRepository: MemberTagsRepository

    // MARK: - Этап 10 (админ-режим)
    /// Единый держатель `AdminSession`: строится **до** пары клиентов (оба берут синхронный bearer
    /// `tokenProvider = { adminSessionHolder.token }`), сидится из `adminTokenStore` (прод — Keychain;
    /// `inMemory` — изолированный in-memory load/save). UI подписывается на `updates`.
    let adminSessionHolder: AdminSessionHolder
    /// Переходы сессии (login/logout/onUnauthorized) поверх cloud-клиента + `adminTokenStore` +
    /// `adminSessionHolder`. Строится **после** клиентов.
    let adminAuthRepository: AdminAuthRepository
    /// `POST /app/race/<id>/tags/` (привязка чипа к КП) на **cloud-клиенте** (админ-операции не ходят
    /// на LAN, как login/logout). Замыкание — `ProvisioningModel` не видит `ApiClient` напрямую (граф
    /// инкапсулирован фабрикой `AppModel.makeProvisioningModel`).
    let bindTag: (Int, Int, String) async -> PostResult<TagBindResponse>

    // MARK: - Этап 9 (LAN-режим + настройки)
    /// Единый держатель текущего `RaceLease` (LAN-пин): координатор пишет через `set(_:)`, пин-гарды
    /// трёх репозиториев читают `value` синхронно (`isRacePinned`), UI подписывается на `updates`.
    /// Сидится из `RaceLeaseStore` (прод — UserDefaults; `inMemory` — изолированный in-memory prefs).
    let leaseHolder: LeaseHolder
    /// Персистнутая настройка темы (`ThemeMode`). `AppModel.themeMode` проксирует её; корневая вьюха
    /// маппит в `.preferredColorScheme`.
    let themePreference: ThemePreference
    /// Оркестратор LAN-режима: probe/enter/exit/refreshAll поверх 4 репозиториев + LAN-клиента.
    /// Конструируется ПОСЛЕ блока репозиториев (захватывает их `refresh*` + `local.fetchSync`), тогда как
    /// `leaseHolder` — ДО него (его читает `isRacePinned`).
    let syncCoordinator: SyncCoordinator

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

    // MARK: - Этап 10 (выгрузка судейских пиков)
    /// Идемпотентный дренаж судейских пиков в обе цели (LAN + облако). Дёргается теми же триггерами
    /// `AppModel`, что marks/track (5-мин таймер / смена команды), плюс fire-and-forget после каждой
    /// записанной строки и выделенный 60-с цикл из `JudgeScanModel` (задача 8). Структурный клон
    /// `trackUploadRepository` с ключом `raceId`.
    let judgeScanUploadRepository: JudgeScanUploadRepository

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
        leaseStore: RaceLeaseStore,
        themePreference: ThemePreference,
        adminTokenStore: AdminTokenStore,
        adminSessionHolder: AdminSessionHolder,
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
        self.installId = installId
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
        self.themePreference = themePreference
        self.adminSessionHolder = adminSessionHolder
        let writer = database.writer

        // Сторы — локальные константы (их захватывают замыкания координатора; ссылка на `self.<store>`
        // до полной инициализации `self` = ошибка «self captured before all members initialized»).
        let raceStore = RaceStore(writer)
        let teamStore = TeamStore(writer)
        let selectedTeamStore = SelectedTeamStore(writer)
        let checkpointStore = CheckpointStore(writer)
        let markStore = MarkStore(writer)
        let legendMetaStore = LegendMetaStore(writer)
        let tagStore = TagStore(writer)
        let memberTagStore = MemberTagStore(writer)
        let memberChipBindingStore = MemberChipBindingStore(writer)
        let syncMetaStore = SyncMetaStore(writer)
        let trackStore = TrackStore(writer)
        let judgeScanStore = JudgeScanStore(writer)
        self.raceStore = raceStore
        self.teamStore = teamStore
        self.selectedTeamStore = selectedTeamStore
        self.checkpointStore = checkpointStore
        self.markStore = markStore
        self.legendMetaStore = legendMetaStore
        self.tagStore = tagStore
        self.memberTagStore = memberTagStore
        self.memberChipBindingStore = memberChipBindingStore
        self.syncMetaStore = syncMetaStore
        self.trackStore = trackStore
        self.judgeScanStore = judgeScanStore

        // Этап 9: держатель lease конструируется ДО репозиториев — его синхронно читает `isRacePinned`
        // (пин-гард трёх pin-guard-репозиториев). Сидится из стора; write-through — обратно в стор.
        let leaseHolder = LeaseHolder(
            initial: leaseStore.read(),
            persist: { lease in
                if let lease { leaseStore.write(lease) } else { leaseStore.clear() }
            }
        )
        self.leaseHolder = leaseHolder
        // Пин-гард: гонка [raceId] обслуживается с LAN, пока её lease жив. `nowMs` — wall clock (`Date()`),
        // а не `TrustedClock` (нужен синхронно, actor-hop недопустим — deviation плана, документирован).
        let leasePinned: (Int) -> Bool = { raceId in
            isPinned(leaseHolder.value, raceId: raceId, nowMs: Int64(Date().timeIntervalSince1970 * 1000))
        }

        let raceRepository = RaceRepository(
            apiClient: cloud,
            raceStore: raceStore,
            syncMetaStore: syncMetaStore,
            origin: cloudOrigin,
            localApiClient: local,
            localOrigin: localOrigin
        )
        let teamRepository = TeamRepository(
            apiClient: cloud,
            teamStore: teamStore,
            selectedTeamStore: selectedTeamStore,
            syncMetaStore: syncMetaStore,
            origin: cloudOrigin,
            localApiClient: local,
            localOrigin: localOrigin,
            isRacePinned: leasePinned
        )
        let legendRepository = LegendRepository(
            apiClient: cloud,
            checkpointStore: checkpointStore,
            tagStore: tagStore,
            legendMetaStore: legendMetaStore,
            syncMetaStore: syncMetaStore,
            origin: cloudOrigin,
            localApiClient: local,
            localOrigin: localOrigin,
            isRacePinned: leasePinned
        )
        let memberTagsRepository = MemberTagsRepository(
            apiClient: cloud,
            memberTagStore: memberTagStore,
            syncMetaStore: syncMetaStore,
            origin: cloudOrigin,
            localApiClient: local,
            localOrigin: localOrigin,
            isRacePinned: leasePinned
        )
        self.raceRepository = raceRepository
        self.teamRepository = teamRepository
        self.legendRepository = legendRepository
        self.memberTagsRepository = memberTagsRepository

        // Этап 10: репозиторий admin-сессии — ПОСЛЕ клиентов (login/logout бьют cloud-клиент). Сессию
        // уже посидировал holder (передан в init ДО клиентов, чтобы оба взяли `tokenProvider`); здесь
        // репозиторий лишь двигает её на login/logout/onUnauthorized и персистит в `adminTokenStore`.
        adminAuthRepository = AdminAuthRepository(
            apiLogin: { email, password in await cloud.login(email: email, password: password) },
            apiLogout: { await cloud.logout() },
            store: adminTokenStore,
            holder: adminSessionHolder
        )
        // Этап 10: провижининг — bind чипа к КП на cloud-клиенте (как login/logout).
        bindTag = { raceId, checkpointId, nfcUid in
            await cloud.bindTag(raceId: raceId, checkpointId: checkpointId, nfcUid: nfcUid)
        }

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

        // Этап 10: дренаж судейских пиков поверх тех же cloud/local-клиентов + `installId`
        // (`source_install_id` тела запроса, без `team_id`). Структурный клон track-дренажа с ключом `raceId`.
        judgeScanUploadRepository = JudgeScanUploadRepository(
            judgeScanStore: judgeScanStore,
            cloud: cloud,
            local: local,
            installId: installId,
            wallNow: wallNow
        )

        // Этап 9: координатор конструируется ПОСЛЕ репозиториев (захватывает их `refresh*` + LAN-клиент).
        // Все зависимости — замыкания-seam; `fetchSync` разворачивает `FetchResult` в `SyncManifestDto?`
        // (`.success` → DTO, иначе `nil`); `nowMs` — тот же wall clock, что `leasePinned`. `selectedRaceId`/
        // `cachedRaces` читают первое значение observation (эмитируется немедленно, как Kotlin-Flow).
        syncCoordinator = SyncCoordinator(
            readLease: { leaseHolder.value },
            writeLease: { leaseHolder.set($0) },
            nowMs: { Int64(Date().timeIntervalSince1970 * 1000) },
            fetchSync: { raceId in
                if case let .success(data, _) = await local.fetchSync(raceId: raceId) { return data }
                return nil
            },
            selectedRaceId: {
                do { for try await sel in selectedTeamStore.observe() { return sel?.raceId } } catch {}
                return nil
            },
            cachedRaces: {
                do { for try await races in raceStore.observeRaces() { return races } } catch {}
                return []
            },
            refreshRaces: { source in (try? await raceRepository.refreshRaces(source: source)) ?? .skipped },
            refreshTeams: { raceId, source in (try? await teamRepository.refreshTeams(raceId, source: source)) ?? .skipped },
            refreshLegend: { raceId, source in (try? await legendRepository.refreshLegend(raceId, source: source)) ?? .skipped },
            refreshMemberTags: { raceId, source in (try? await memberTagsRepository.refreshMemberTags(raceId, source: source)) ?? .skipped }
        )
    }

    // MARK: - Фабрики

    /// Прод: файловая БД (`AppDatabase.makeShared`) + пара cloud/LAN-клиентов над общим
    /// `TrustedClock`/`InstallId` (`ApiClients.makeDefaultPair`). Origins = base URL'ы из `Secrets`.
    static func makeShared() throws -> AppEnvironment {
        let database = try AppDatabase.makeShared()
        // Этап 10: admin-сессия сидится из Keychain и держатель строится ДО пары клиентов, чтобы оба
        // (cloud + LAN) получили синхронный bearer `tokenProvider = { holder.token }` поверх подписи.
        let adminTokenStore = AdminTokenStore.fromKeychain()
        let adminSessionHolder = AdminSessionHolder(
            initial: AdminSessionHolder.seed(store: adminTokenStore, nowUtcIso: nowUtcIso())
        )
        let pair = ApiClients.makeDefaultPair(tokenProvider: { adminSessionHolder.token })
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
            // Этап 9: lease/тема персистятся в UserDefaults (тот же адаптер-идиома, что `ClockAnchorStore`).
            leaseStore: RaceLeaseStore.fromUserDefaults(),
            themePreference: ThemePreference.fromUserDefaults(),
            adminTokenStore: adminTokenStore,
            adminSessionHolder: adminSessionHolder,
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
        requestLocationAuthorization: @escaping @Sendable () -> Void = {},
        adminTokenStore: AdminTokenStore? = nil
    ) throws -> AppEnvironment {
        let database = try AppDatabase.makeInMemory()
        // In-memory prefs (изолированы от `UserDefaults.standard` — тесты не пишут глобальное состояние
        // и не видят чужой lease/тему). Свежий бокс на каждый `inMemory`-граф.
        let prefs = InMemoryPrefs()
        let leaseStore = RaceLeaseStore(
            load: { prefs.get($0) },
            save: { prefs.set($0, $1) }
        )
        let themePreference = ThemePreference(
            load: { prefs.get(ThemePreference.keyThemeMode) },
            save: { prefs.set(ThemePreference.keyThemeMode, $0) }
        )
        // Этап 10: admin-стор — инъецируемый (тесты передают свой, чтобы посидировать/проверять его),
        // иначе изолированный in-memory (Keychain в тестах НЕ трогается). Держатель строится ДО клиентов,
        // оба берут его bearer.
        let tokenStore = adminTokenStore ?? Self.makeInMemoryAdminStore()
        let adminSessionHolder = AdminSessionHolder(
            initial: AdminSessionHolder.seed(store: tokenStore, nowUtcIso: nowUtcIso())
        )
        return AppEnvironment(
            database: database,
            cloud: testClient(
                baseURL: cloudOrigin, transport: transport,
                tokenProvider: { adminSessionHolder.token }
            ),
            local: testClient(
                baseURL: localOrigin, transport: transport,
                tokenProvider: { adminSessionHolder.token }
            ),
            installId: "install-test",
            cloudOrigin: cloudOrigin,
            localOrigin: localOrigin,
            leaseStore: leaseStore,
            themePreference: themePreference,
            adminTokenStore: tokenStore,
            adminSessionHolder: adminSessionHolder,
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
    /// Изолированный in-memory `AdminTokenStore` для `inMemory`-графа (этап 10): не трогает Keychain,
    /// свежий бокс на каждый граф (тесты не видят чужую сессию). Тесты, которым нужно ассертить/сидировать
    /// стор, передают собственный через параметр `adminTokenStore:`.
    private static func makeInMemoryAdminStore() -> AdminTokenStore {
        let box = InMemoryDataBox()
        return AdminTokenStore(load: { box.value }, save: { box.value = $0 })
    }

    static func makeTestClock() -> TrustedClock {
        TrustedClock(
            elapsedProvider: { 0 },
            wallProvider: { 0 },
            bootCountProvider: { nil }
        )
    }

    private static func testClient(
        baseURL: String,
        transport: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse),
        tokenProvider: @escaping () -> String? = { nil }
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
            tokenProvider: tokenProvider,
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

/// In-memory key-value backing для `inMemory`-графа (этап 9): подкладывается под `RaceLeaseStore`/
/// `ThemePreference` вместо `UserDefaults.standard`, чтобы тесты не писали глобальное состояние.
private final class InMemoryPrefs: @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: String] = [:]

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return store[key]
    }

    func set(_ key: String, _ value: String?) {
        lock.lock(); defer { lock.unlock() }
        store[key] = value
    }
}

/// In-memory `Data?`-бокс для дефолтного admin-стора `inMemory`-графа (этап 10): подкладывается под
/// `AdminTokenStore` вместо Keychain, чтобы тесты не писали в системный Keychain.
private final class InMemoryDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Data?

    var value: Data? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
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
