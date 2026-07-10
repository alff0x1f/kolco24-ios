//
//  TrackRecorder.swift
//  kolco24
//
//  `@Observable @MainActor`-редьюсер записи GPS-трека. Порт ПОВЕДЕНИЯ (не структуры) верхней,
//  Android-free части `TrackRecordingService.kt` (`onStartCommand`/`startEngine`/`teardown`) — сам
//  `Service`/нотификация/канал/wakelock/flush-таймаут не портируются (iOS: фоновые обновления держит
//  `CLBackgroundActivitySession`, а `CLLocationUpdate` отдаёт фиксы сразу — lossless-стоп = «отменить
//  цикл, дописать пришедшее», см. `TrackEngine`).
//
//  Один экземпляр живёт в `AppModel` (переживает уходы с таба). Зависит только от чистых `Core/`-фн
//  (`makeTrackPoints`/`shouldKeepFix`/`shouldLiveUpload`/`nextSegmentId`), швов (`TrackEngine`) и
//  сторов/репозиториев — поэтому `import SwiftUI`/`GRDB`/`CoreLocation` запрещены (grep-инвариант),
//  хватает `Observation`/`Foundation`, и вся логика тестируется через `FakeTrackEngine` + управляемое
//  время (идиома `ScanModel`).
//
//  Ключевые правила (locked `TrackRecorderTests`):
//  - **Даунсемплинг**: CoreLocation отдаёт ~1 Гц; `shouldKeepFix` (15 с) выравнивает плотность с Android.
//  - **Батч-маппинг**: снимок `wallNow`/`elapsedNow`/`bootCount` на фикс; `trustedMs` — заранее
//    `await`-нутый `TrustedClock.trustedAt` (actor в sync-замыкание не заворачивается), передаётся в
//    `makeTrackPoints` готовым.
//  - **Персист** — в неструктурированном `Task`, захватывающем СТОР (не `self`): закрытие UI / уход с
//    таба / стоп не рвут вставку (§6 этапа 5). Вставка идемпотентна (INSERT OR IGNORE по UUID).
//  - **Live-upload**: на сохранённом фиксе `shouldLiveUpload` (10 мин) → после вставки дослать точки
//    трека И взятия (пиггибек на GPS-пробуждение) — обе цели, self-heal.
//  - **Идемпотентный старт**: повторный `start` при живой записи — no-op (тот же сегмент); стоп→старт
//    минтит новый сегмент.
//

import Foundation
import Observation

@MainActor
@Observable
final class TrackRecorder {

    /// Состояние записи (порт `TrackState.kt`). `pointCount` вынесен из enum отдельной наблюдаемой
    /// подпиской (`countForTeam`) — это сырой live-счётчик БД, а не фильтрованная idle-метрика карточки.
    enum TrackState: Equatable {
        case idle
        case recording(teamId: Int)
    }

    // MARK: - Наблюдаемое состояние

    /// Текущее состояние записи (драйвит TrackCard: «Идёт запись» / «Начать запись»).
    private(set) var state: TrackState = .idle
    /// Живой счётчик точек текущей команды (сырой `countForTeam`) — «N точек» без отдельного запроса.
    private(set) var pointCount: Int = 0

    /// Колбэк отказа геодоступа (TOCTOU-проверка перед стартом): `AppModel` вешает сюда показ тоста.
    @ObservationIgnored var onGeoDenied: (() -> Void)?

    // MARK: - Зависимости (граф — через AppModel)

    @ObservationIgnored private let trackStore: TrackStore
    @ObservationIgnored private let trackUploadRepository: TrackUploadRepository
    @ObservationIgnored private let markUploadRepository: MarkUploadRepository
    @ObservationIgnored private let trustedClock: TrustedClock
    /// Фабрика движка (прод — `CoreLocationTrackEngine`; тесты — `FakeTrackEngine`).
    @ObservationIgnored private let makeEngine: () -> any TrackEngine
    /// TOCTOU-проверка разрешения на геолокацию (чтение `authorizationStatus` с удерживаемого менеджера).
    @ObservationIgnored private let hasLocationAccess: () -> Bool
    /// Прогрев разрешения «при использовании» при тапе «Начать запись» (идемпотентно; при `.notDetermined`
    /// — системный диалог, иначе no-op). Первый старт из TrackCard без единого открытия скан-оверлея.
    @ObservationIgnored private let requestAuthorization: () -> Void
    /// Снимок стенных/монотонных часов и boot-сессии для `makeTrackPoints` (инжектится ради
    /// управляемого времени в тестах; в проде — системные провайдеры).
    @ObservationIgnored private let wallNow: () -> Int64
    @ObservationIgnored private let elapsedNow: () -> Int64
    @ObservationIgnored private let bootCount: () -> Int?
    @ObservationIgnored private let idFactory: () -> String

    // MARK: - Состояние одной сессии записи

    /// Изменяемое состояние ОДНОЙ сессии записи (сегмент + счётчики даунсемплинга/троттлинга). Ссылочный
    /// тип, захватываемый циклом фиксов, — так поздний (уже буферизованный) фикс СТАРОЙ сессии, дренящийся
    /// после стоп→старт, обновляет СВОЙ объект, а не счётчики новой сессии (сегментная изоляция).
    /// Мутируется только на MainActor (в `handleFix`) — гонки нет.
    private final class Session {
        let segmentId: String
        let raceId: Int
        let teamId: Int
        /// Монотонный `elapsedMs` последнего СОХРАНЁННОГО фикса — база даунсемплинга (`shouldKeepFix`).
        var lastKeptElapsed: Int64?
        /// Монотонный `elapsedMs` последней live-загрузки — база троттлинга (`shouldLiveUpload`).
        var lastLiveUploadElapsed: Int64?

        init(segmentId: String, raceId: Int, teamId: Int) {
            self.segmentId = segmentId
            self.raceId = raceId
            self.teamId = teamId
        }
    }

    /// Текущая сессия записи (`nil` в idle). Держит скоуп для opportunistic-выгрузки на стопе.
    @ObservationIgnored private var session: Session?

    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var countTask: Task<Void, Never>?
    @ObservationIgnored private var engine: (any TrackEngine)?

    init(
        trackStore: TrackStore,
        trackUploadRepository: TrackUploadRepository,
        markUploadRepository: MarkUploadRepository,
        trustedClock: TrustedClock,
        makeEngine: @escaping () -> any TrackEngine,
        hasLocationAccess: @escaping () -> Bool,
        requestAuthorization: @escaping () -> Void = {},
        wallNow: @escaping () -> Int64 = { SystemClockProviders.wallClockMs() },
        elapsedNow: @escaping () -> Int64 = { SystemClockProviders.elapsedRealtimeMs() },
        bootCount: @escaping () -> Int? = { SystemClockProviders.bootCount() },
        idFactory: @escaping () -> String = { UUID().uuidString }
    ) {
        self.trackStore = trackStore
        self.trackUploadRepository = trackUploadRepository
        self.markUploadRepository = markUploadRepository
        self.trustedClock = trustedClock
        self.makeEngine = makeEngine
        self.hasLocationAccess = hasLocationAccess
        self.requestAuthorization = requestAuthorization
        self.wallNow = wallNow
        self.elapsedNow = elapsedNow
        self.bootCount = bootCount
        self.idFactory = idFactory
    }

    // MARK: - Старт / стоп

    /// Начать запись трека команды `(raceId, teamId)`. TOCTOU-проверка геодоступа (отказ → тост-колбэк,
    /// запись не стартует); идемпотентность — повторный старт при живой записи no-op (тот же сегмент,
    /// движок не пересоздаётся). Стоп→старт минтит новый сегмент (`segmentId == nil` после стопа).
    func start(raceId: Int, teamId: Int) {
        // Прогрев разрешения при тапе (идемпотентно): первый старт из TrackCard может случиться до любого
        // открытия скан-оверлея — без этого `.notDetermined` навсегда читается как отказ, и запись не идёт.
        // При `.notDetermined` система покажет диалог (ответ асинхронный — первый тап может ещё не стартовать,
        // повторный после «Разрешить» запишет); при уже определённом статусе — no-op.
        requestAuthorization()
        // TOCTOU: разрешение подтверждали до старта, но его могли отозвать в промежутке.
        guard hasLocationAccess() else {
            onGeoDenied?()
            return
        }
        // Идемпотентный повторный вход: запись уже идёт — держим один сегмент/движок, не рестартуем.
        if case .recording = state { return }

        // Свежий сегмент на подлинно новой сессии (в idle сессии нет → `nextSegmentId` всегда минтит).
        let segment = nextSegmentId(current: session?.segmentId, wasTearingDown: false, mint: idFactory)
        let session = Session(segmentId: segment, raceId: raceId, teamId: teamId)
        self.session = session
        state = .recording(teamId: teamId)

        startPointCountObservation(raceId: raceId, teamId: teamId)

        let engine = makeEngine()
        self.engine = engine
        let fixes = engine.fixes()
        // Цикл НЕ отменяется на стопе: `engine.stop()` завершает стрим, и цикл сперва дренирует уже
        // буферизованные (пришедшие) фиксы, а лишь потом выходит — lossless-стоп. Захватывает `session`
        // (не читает `self.session`), поэтому дренаж старой сессии после стоп→старт не путается с новой.
        loopTask = Task { [weak self] in
            for await fix in fixes {
                guard let self else { return }
                await self.handleFix(fix, session: session)
            }
            // Стрим завершился НЕ через наш `stop()` (отзыв геодоступа mid-record / транзиентная ошибка
            // CoreLocation → `CoreLocationTrackEngine` сам закрывает стрим). Без этого состояние навсегда
            // застряло бы в `.recording` (TrackCard «Идёт запись», ни синего индикатора, ни новых фиксов).
            guard let self else { return }
            self.finishIfStreamEndedFor(session)
        }
    }

    /// Стрим движка иссяк сам (не через `stop()`): если это всё ещё ТЕКУЩАЯ сессия (стоп/старт между
    /// делом не подменили её — тогда `session !== self.session` и мы молчим), откатываемся в `.idle` и
    /// чистим состояние как `stop()`, плюс опортунистический дренаж уже вставленных точек/взятий.
    private func finishIfStreamEndedFor(_ session: Session) {
        // Гвард сегментной изоляции: если стоп→старт подменили текущую сессию — молчим. Иначе `stop()`
        // делает ровно тот же teardown (тот же скоуп дренажа — `self.session === session`), не дублируем.
        guard self.session === session else { return }
        stop()
    }

    /// Остановить запись: отмена цикла + движок, сброс сессии в idle, opportunistic-дренаж точек трека
    /// и взятий (fire-and-forget, захват репозиториев — переживает teardown). Идемпотентна (idle → no-op
    /// по скоупу).
    func stop() {
        // Цикл фиксов НЕ отменяем: `engine.stop()` завершит стрим, цикл дренирует уже пришедшие фиксы и
        // выйдет сам (lossless). Счётчик точек можно гасить сразу — это лишь UI-наблюдение.
        countTask?.cancel()
        countTask = nil
        engine?.stop()
        engine = nil

        let scope = session
        session = nil
        loopTask = nil
        pointCount = 0
        state = .idle

        // Опортунистический дренаж обеих целей на стопе (порт `finishTeardown`): точки трека + взятия.
        // Захватывает репозитории (не `self`) — переживает закрытие/уход с таба.
        if let scope {
            let trackRepo = trackUploadRepository
            let markRepo = markUploadRepository
            Task { await trackRepo.uploadPending(raceId: scope.raceId, teamId: scope.teamId) }
            Task { await markRepo.uploadPending(raceId: scope.raceId, teamId: scope.teamId) }
        }
    }

    // MARK: - Обработка фикса

    /// Порт `startEngine.onPoints`: даунсемплинг → маппинг батча (trusted заранее `await`-нут) →
    /// персист в захватившем стор `Task` → live-upload на троттлинге. Сериализовано единым `for await`.
    private func handleFix(_ fix: RawFix, session: Session) async {
        let nowElapsed = fix.elapsedRealtimeNanos / 1_000_000

        // Даунсемплинг: CoreLocation ~1 Гц → держим целевой интервал 15 с (первый фикс всегда сохраняется).
        guard shouldKeepFix(
            nowElapsed: nowElapsed, lastKeptElapsed: session.lastKeptElapsed, intervalMs: TRACK_SAMPLE_INTERVAL_MS
        ) else { return }
        session.lastKeptElapsed = nowElapsed

        // Троттлинг live-загрузки решается ЗДЕСЬ (сериализованно), штамп — до единственного `await`.
        let doUpload = shouldLiveUpload(
            nowElapsed: nowElapsed, lastUploadElapsed: session.lastLiveUploadElapsed,
            minIntervalMs: LIVE_UPLOAD_MIN_INTERVAL_MS
        )
        if doUpload { session.lastLiveUploadElapsed = nowElapsed }
        let raceId = session.raceId
        let teamId = session.teamId
        let boot = bootCount()
        // Снимок часов до `await` — back-projection wallMs честен per-point (Technical Details).
        let wall = wallNow()
        let elapsed = elapsedNow()

        // Доверенное время фикса: `TrustedClock.trustedAt` — actor-isolated async, `await`-им ЗДЕСЬ, в
        // sync-замыкание `makeTrackPoints` не заворачиваем (семафорный мост на main запрещён). Всё
        // состояние — в захваченном `session`, поэтому стоп/старт во время ожидания часов не роняет вставку
        // уже пришедшего фикса и не путает сегменты (lossless-стоп + сегментная изоляция).
        let trusted = await trustedClock.trustedAt(elapsedAt: nowElapsed, bootAt: boot)

        let points = makeTrackPoints(
            fixes: [fix], raceId: raceId, teamId: teamId, segmentId: session.segmentId,
            wallNow: wall, elapsedNow: elapsed, bootCount: boot,
            trustedMsFor: { _ in trusted }, idFactory: idFactory
        )

        // Персист + (опц.) live-upload в неструктурированном Task, захватившем стор/репозитории (§6):
        // порядок insert → uploadPending как в Kotlin (`applicationScope.launch { insertAll; upload }`),
        // так только что вставленная точка гарантированно видна дренажу. Захват — не `self`.
        let store = trackStore
        let trackRepo = trackUploadRepository
        let markRepo = markUploadRepository
        Task {
            try? await store.insertAll(points)
            if doUpload {
                await trackRepo.uploadPending(raceId: raceId, teamId: teamId)
                // Пиггибек: тем же пробуждением дослать и взятия (near-real-time организаторам).
                await markRepo.uploadPending(raceId: raceId, teamId: teamId)
            }
        }
    }

    // MARK: - Наблюдение счётчика точек

    private func startPointCountObservation(raceId: Int, teamId: Int) {
        countTask?.cancel()
        let observation = trackStore.countForTeam(teamId: teamId, raceId: raceId)
        countTask = Task { [weak self] in
            do {
                for try await count in observation {
                    guard let self, !Task.isCancelled else { return }
                    self.pointCount = count
                }
            } catch {}
        }
    }
}
