//
//  AppModel.swift
//  kolco24
//
//  Кросс-экранная `@Observable @MainActor`-модель: разрешение выбранной команды + оркестрация
//  refresh'ей. Порт поведения (НЕ структуры) двух мест Android: `produceState`-цепочки
//  `SelectedTeamState` из `MainActivity.kt` (~683) и стартовых корутин Launch A/B из `Kolco24App.kt`.
//
//  В Android этих состояний нет как отдельного слоя — всё живёт в 2220-строчном composable. На iOS
//  оно вынесено в идиоматичную `@Observable`-модель (iOS 18). Источник всегда `.cloud` (LAN/lease —
//  этап 9). `import SwiftUI` здесь запрещён (grep-инвариант) — хватает `Observation`.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppModel {

    /// Порт `sealed interface SelectedTeamState` из `MainActivity.kt`. `loading` подавляет мигание
    /// empty-состояния, пока observation команды ещё не эмитировал; `missing` — команда исчезла
    /// (например, удалена сервером при resync).
    enum SelectedTeamState: Equatable {
        case none
        case loading
        case missing
        case present(Team)
    }

    /// Разрешённое состояние выбранной команды (для вкладок).
    private(set) var selectedTeamState: SelectedTeamState = .loading
    /// Id гонки/команды выбранной команды (для реактивных подписок per-tab моделей).
    private(set) var selectedRaceId: Int?
    private(set) var selectedTeamId: Int?
    /// Последняя ошибка refresh (текст тоста). Успех молчалив (`nil`).
    var toastMessage: String?

    /// Единый рекордер GPS-трека (этап 8): один экземпляр на весь жизненный цикл приложения (переживает
    /// уходы с таба). Вьюха «Команда» держит его напрямую (`@Observable` — SwiftUI трекает
    /// `state`/`pointCount`); смена/сброс выбранной команды останавливает живую запись (см. `handleSelection`).
    let trackRecorder: TrackRecorder

    /// Интервал повторной попытки дренажа выгрузки (`UPLOAD_RETRY_INTERVAL_MS`, имя как в Kotlin).
    /// Инжектится, чтобы тесты не ждали реальные 5 минут.
    static let uploadRetryIntervalMs = 300_000

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let uploadRetryIntervalMs: Int
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var innerTeamTask: Task<Void, Never>?
    /// 5-минутный foreground-цикл дренажа выгрузки (порт таймера `MainActivity.kt` L167/589–597).
    /// Пересоздаётся `scenePhaseChanged(isActive:)` (аналог `repeatOnLifecycle(STARTED)`).
    @ObservationIgnored private var uploadLoopTask: Task<Void, Never>?
    /// Гонка, для которой уже отработал реактивный refresh (Launch B) — чтобы не перезапускать его на
    /// повторных эмиссиях той же гонки. `nil` при сбросе выбора → повторный выбор той же гонки снова
    /// дёрнет refresh.
    @ObservationIgnored private var lastReactiveRaceId: Int?

    init(
        env: AppEnvironment,
        now: @escaping () -> Date = { Date() },
        uploadRetryIntervalMs: Int = AppModel.uploadRetryIntervalMs
    ) {
        self.env = env
        self.now = now
        self.uploadRetryIntervalMs = uploadRetryIntervalMs
        self.trackRecorder = TrackRecorder(
            trackStore: env.trackStore,
            trackUploadRepository: env.trackUploadRepository,
            markUploadRepository: env.markUploadRepository,
            trustedClock: env.trustedClock,
            makeEngine: env.makeEngine,
            hasLocationAccess: env.hasLocationAccess,
            requestAuthorization: env.requestLocationAuthorization
        )
        // Отказ геодоступа на старте записи → тост (все stored props уже проинициализированы — `self` готов).
        trackRecorder.onGeoDenied = { [weak self] in
            self?.toastMessage = "Нет доступа к геолокации — разрешите его в настройках, чтобы записывать трек."
        }
    }

    // MARK: - Жизненный цикл

    /// Вызывается один раз из `.task` корневой вьюхи. Запускает подписку на выбранную команду,
    /// 5-минутный цикл дренажа выгрузки и стартовый refresh (Launch A). Идемпотентен по подписке.
    func start() async {
        startSelectionObservationIfNeeded()
        startUploadLoop()
        sweepOrphanPhotoDirs()
        await launchStartupRefresh()
    }

    /// Стартовый sweep осиротевших фото-каталогов (этап 7, fire-and-forget): кадры, чья строка взятия
    /// так и не записалась (смерть процесса mid-capture), подбираются. Захватывает стор/замыкание графа
    /// (не `self`): `markStore.allIds()` → `sweepOrphanPhotoDirs`. Порт `sweepOrphanPhotoDirs` из
    /// `Kolco24App.kt` (startup). Ошибка чтения id → sweep пропускается (пустой набор снёс бы каталоги
    /// живых взятий).
    private func sweepOrphanPhotoDirs() {
        let markStore = env.markStore
        let sweep = env.sweepOrphanPhotoDirs
        Task {
            guard let ids = try? await markStore.allIds() else { return }
            let liveIds = Set(ids)
            // Синхронный `sweep` перечисляет/удаляет каталоги (диск I/O); этот `Task` наследует
            // исполнитель `@MainActor`, поэтому уводим блокирующую работу с главного потока.
            Task.detached { sweep(liveIds) }
        }
    }

    /// (Пере)запустить 5-минутный foreground-цикл дренажа выгрузки: сразу пробует дослать всё
    /// накопленное, затем спит `uploadRetryIntervalMs` мс и повторяет. Порт таймера из
    /// `MainActivity.kt` (L167/589–597, `repeatOnLifecycle(STARTED)`). Захватывает репозиторий (не
    /// `self`), но привязан к жизни `uploadLoopTask` — отменяется на уходе в фон.
    private func startUploadLoop() {
        uploadLoopTask?.cancel()
        let repo = env.markUploadRepository
        let trackRepo = env.trackUploadRepository
        let intervalMs = uploadRetryIntervalMs
        uploadLoopTask = Task {
            while !Task.isCancelled {
                await repo.uploadAllPending()
                // Этап 8: тем же таймером досылаем и точки трека (обе цели, self-heal).
                await trackRepo.uploadAllPending()
                do {
                    try await Task.sleep(for: .milliseconds(intervalMs))
                } catch {
                    return // отменён (уход в фон)
                }
            }
        }
    }

    /// Аналог `repeatOnLifecycle(STARTED)`: на `.active` перезапускаем цикл (немедленный fire —
    /// возврат в приложение сразу пробует дослать), на фон — отменяем, чтобы не крутить таймер.
    /// Пробрасывается `ContentView` из `@Environment(\.scenePhase)`.
    func scenePhaseChanged(isActive: Bool) {
        if isActive {
            startUploadLoop()
        } else {
            uploadLoopTask?.cancel()
            uploadLoopTask = nil
        }
    }

    // MARK: - Подписка на выбранную команду (порт produceState)

    private func startSelectionObservationIfNeeded() {
        guard selectionTask == nil else { return }
        let observation = env.selectedTeamStore.observe()
        selectionTask = Task { [weak self] in
            // observation может бросить (ошибка БД) — гасим: как Kotlin-Flow, на практике не бросает.
            do {
                for try await selection in observation {
                    guard let self else { return }
                    await self.handleSelection(selection)
                }
            } catch {}
        }
    }

    /// Порт тела `produceState` + реактивный триггер Launch B. На новой выбранной команде: отменяет
    /// вложенное наблюдение прежней команды, публикует id'шники, выставляет `.loading`, дёргает
    /// реактивный refresh при смене гонки и перезапускает `observeTeamById`.
    private func handleSelection(_ selection: SelectedTeam?) async {
        // Этап 8: останавливаем живую запись трека ТОЛЬКО при подлинной смене команды (или сбросе). На
        // стартовой эмиссии и на повторной эмиссии той же команды (resync) запись не трогаем —
        // безусловный `stop()` молча убил бы её (порт guard'а `MainActivity.kt` L893–899).
        if case let .recording(recTeamId) = trackRecorder.state, selection?.teamId != recTeamId {
            trackRecorder.stop()
        }

        innerTeamTask?.cancel()
        selectedRaceId = selection?.raceId
        selectedTeamId = selection?.teamId

        guard let selection else {
            selectedTeamState = .none
            lastReactiveRaceId = nil
            return
        }

        selectedTeamState = .loading

        // Этап 6: смена выбранной команды (и первая эмиссия на старте) — оппортунистический дренаж
        // всех pending-взятий (порт flush из `Kolco24App.kt` L84–99). Fire-and-forget, guard'ится актором.
        let uploadRepo = env.markUploadRepository
        Task { await uploadRepo.uploadAllPending() }
        // Этап 8: смена команды (и первая эмиссия) — заодно оппортунистический дренаж точек трека.
        let trackRepo = env.trackUploadRepository
        Task { await trackRepo.uploadAllPending() }

        // Launch B: реактивный refresh при смене гонки (teams/legend/member_tags), ошибка → тост.
        if selection.raceId != lastReactiveRaceId {
            lastReactiveRaceId = selection.raceId
            let raceId = selection.raceId
            Task { [weak self] in await self?.reactiveRefresh(raceId: raceId) }
        }

        let observation = env.teamStore.observeTeamById(selection.teamId)
        innerTeamTask = Task { [weak self] in
            do {
                for try await team in observation {
                    guard let self, !Task.isCancelled else { return }
                    self.selectedTeamState = team.map(SelectedTeamState.present) ?? .missing
                }
            } catch {}
        }
    }

    // MARK: - Действия выбора

    /// Персистит выбранную команду; подписка сама переключит состояние и подтянет данные.
    func selectTeam(raceId: Int, teamId: Int) async {
        try? await env.selectedTeamStore.upsert(SelectedTeam(raceId: raceId, teamId: teamId))
    }

    func clearTeam() async {
        try? await env.selectedTeamStore.clear()
    }

    /// Fire-and-forget дренаж выгрузки одного скоупа `(raceId, teamId)` — шов для закрытия
    /// скан-оверлея (порт flush из `MainActivity.kt` L1311–1319). Захватывает **репозиторий** (не
    /// `self`): закрытие шита не абортит начатую выгрузку (§6-идиома этапа 5). Вызывается из `MarksView`
    /// (`.sheet(item:onDismiss:)`), где `AppModel` в `@Environment`, — у `ScanSheet` доступа к нему нет.
    func flushUploads(raceId: Int, teamId: Int) {
        let repo = env.markUploadRepository
        Task { await repo.uploadPending(raceId: raceId, teamId: teamId) }
    }

    /// Фабрика модели флоу выбора гонки/команды. Держит `env` инкапсулированным (вьюхи не видят
    /// граф зависимостей): `TeamPickerModel` получает и `env`, и обратную ссылку на этот `AppModel`
    /// (для `confirm` → `selectTeam`). `now` прокидывается для тестируемого `today`.
    func makeTeamPickerModel(now: @escaping () -> Date = { Date() }) -> TeamPickerModel {
        TeamPickerModel(env: env, appModel: self, now: now)
    }

    /// Фабрика модели вкладки «Команда» (наблюдение привязок чипов + отвязка + производные трека).
    /// Держит `env` инкапсулированным — вьюха не видит граф зависимостей. `isReducedAccuracy`
    /// протянут из графа (этап 8) для хинта деградации точности в TrackCard.
    func makeTeamModel() -> TeamModel {
        TeamModel(env: env, isReducedAccuracy: env.isReducedAccuracy)
    }

    /// Фабрика модели вкладки «Легенда» (наблюдение КП/агрегатов/взятий). Держит `env`
    /// инкапсулированным.
    func makeLegendModel() -> LegendModel {
        LegendModel(env: env)
    }

    /// Фабрика модели вкладки «Отметки» (наблюдение взятий/КП/агрегатов/привязок). Держит `env`
    /// инкапсулированным.
    func makeMarksModel() -> MarksModel {
        MarksModel(env: env)
    }

    /// Фабрика модели экрана «Загрузка данных» (этап 6). Привязывается к ТЕКУЩЕМУ скоупу выбора
    /// (`selectedRaceId`/`selectedTeamId`) — шит открывается для выбранной команды. Держит `env`
    /// инкапсулированным; `nowMs` прокидывается для тестируемого относительного времени.
    func makeUploadModel(
        nowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) -> UploadModel {
        let model = UploadModel(env: env, nowMs: nowMs)
        model.rebind(teamId: selectedTeamId, raceId: selectedRaceId)
        return model
    }

    /// Фабрика хост-редьюсера скан-оверлея (этап 5). Собирается из графа (`legendRepository`, сторы,
    /// `trustedClock.sample` для монотонного окна, `locationProvider`, `feedback`) + ростер выбранной
    /// команды. Возвращает `nil`, когда команда не выбрана (нет ростера — сканировать некуда). Сканер
    /// (`any ChipScanning`) подаётся отдельно через `ScanModel.start(scanner:)` — прод `NfcChipScanner`
    /// подключит вьюха в задаче 8; тесты задачи 4 передают `FakeChipScanner`.
    func makeScanModel() -> ScanModel? {
        guard case let .present(team) = selectedTeamState,
              let raceId = selectedRaceId,
              let teamId = selectedTeamId
        else { return nil }
        let clock = env.trustedClock
        let model = ScanModel(
            raceId: raceId,
            teamId: teamId,
            roster: team.members,
            legendRepository: env.legendRepository,
            markStore: env.markStore,
            bindingStore: env.memberChipBindingStore,
            locationProvider: env.locationProvider,
            feedback: env.feedback,
            elapsedNowMs: { await clock.sample().elapsedMs }
        )
        // Прод-сканер `NfcChipScanner` (из `Nfc/`) инстанцируется здесь — App-слой в одном модуле,
        // импорт CoreNFC не нужен (grep-инвариант). Семпл доверенного времени берётся ДО чтения чипа
        // (§8) синхронным мостом к актору-часам (вызов на выделенной NFC-очереди, не на кооперативном
        // пуле — блокировка безопасна); `shouldRestart` читает потокобезопасный `liveness` (не @MainActor
        // `closeRequested` с чужой очереди — то была бы гонка данных, Finding-3), §60-с рестарт.
        let liveness = model.liveness
        let scanner = NfcChipScanner(
            sampleNow: { AppModel.syncSample(clock) },
            shouldRestart: { liveness.isAlive }
        )
        model.attachProductionScanner(scanner)
        return model
    }

    /// Фабрика хост-редьюсера фото-отметки (этап 7). Собирается из графа (`checkpointStore`, `markStore`,
    /// `trustedClock.sample` для времени/окна, `locationProvider`, дисковые замыкания `writeFrame`/
    /// `deleteFrame`) + размер ростера выбранной команды. Возвращает `nil`, когда команда не выбрана
    /// (вьюха тогда зовёт `onChooseTeam`). Держит `env` инкапсулированным.
    func makePhotoModel() -> PhotoModel? {
        guard case let .present(team) = selectedTeamState,
              let raceId = selectedRaceId,
              let teamId = selectedTeamId
        else { return nil }
        let clock = env.trustedClock
        return PhotoModel(
            raceId: raceId,
            teamId: teamId,
            rosterSize: team.members.count,
            checkpointStore: env.checkpointStore,
            markStore: env.markStore,
            locationProvider: env.locationProvider,
            sampleNow: { await clock.sample() },
            writeFrame: env.writeFrame,
            deleteFrame: env.deleteFrame
        )
    }

    /// Синхронный мост к актору `TrustedClock` для `NfcChipScanner.sampleNow` (§8). Вызывается на
    /// выделенной NFC-делегатной очереди (не на кооперативном пуле Swift Concurrency), поэтому
    /// короткое семафорное ожидание не роняет рантайм — та же санкционированная кодовой базой техника,
    /// что и мост `sendMiFareCommand` в `MiFareTransport`.
    nonisolated static func syncSample(_ clock: TrustedClock) -> TimeSample {
        final class Box: @unchecked Sendable { var value: TimeSample? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await clock.sample()
            sem.signal()
        }
        sem.wait()
        return box.value ?? TimeSample(wallMs: 0, elapsedMs: 0, trustedMs: nil, bootCount: nil)
    }

    // MARK: - Refresh-оркестрация (всё .cloud)

    /// Launch A (порт `Kolco24App.kt`): одноразовый refresh гонок + прогрев ближайшей текущей гонки
    /// (teams/legend/member_tags параллельно, результаты игнорируются — best-effort, тост молчит).
    private func launchStartupRefresh() async {
        _ = try? await env.raceRepository.refreshRaces()
        guard let nearest = nearestRaceId(await currentRaces(), today: todayIso(now: now())) else {
            return
        }
        async let teams = try? env.teamRepository.refreshTeams(nearest)
        async let legend = try? env.legendRepository.refreshLegend(nearest)
        async let tags = try? env.memberTagsRepository.refreshMemberTags(nearest)
        _ = await (teams, legend, tags)
    }

    /// Launch B: реактивный refresh при смене гонки. Ошибка → `toastMessage`.
    private func reactiveRefresh(raceId: Int) async {
        async let teams = try? env.teamRepository.refreshTeams(raceId)
        async let legend = try? env.legendRepository.refreshLegend(raceId)
        async let tags = try? env.memberTagsRepository.refreshMemberTags(raceId)
        let results = [await teams, await legend, await tags]
        // Stale-guard: гонка могла смениться, пока fan-out был в полёте. В Android этот блок живёт
        // под `collectLatest` — смена команды отменяет in-flight refresh, поэтому его ошибка тоста
        // не показывает; здесь Task не отменяется, гасим stale-тост явной проверкой.
        guard selectedRaceId == raceId else { return }
        publishError(from: results)
    }

    /// Pull-to-refresh «Легенды»: точечный refresh легенды гонки [raceId], ошибка → `toastMessage`.
    func refreshLegend(raceId: Int) async {
        let result = try? await env.legendRepository.refreshLegend(raceId)
        publishError(from: [result])
    }

    /// Pull-to-refresh «Команды»: fan-out всех 4 refresh для текущей гонки, тост — первая ошибка.
    func refreshAll() async {
        guard let raceId = selectedRaceId else {
            let result = try? await env.raceRepository.refreshRaces()
            publishError(from: [result])
            return
        }
        async let races = try? env.raceRepository.refreshRaces()
        async let teams = try? env.teamRepository.refreshTeams(raceId)
        async let legend = try? env.legendRepository.refreshLegend(raceId)
        async let tags = try? env.memberTagsRepository.refreshMemberTags(raceId)
        let results = [await races, await teams, await legend, await tags]
        // Stale-guard (см. `reactiveRefresh`): пользователь мог сменить гонку за время fan-out.
        guard selectedRaceId == raceId else { return }
        publishError(from: results)
    }

    // MARK: - Хелперы

    /// Текущий список гонок (первое значение observation — эмитируется немедленно).
    private func currentRaces() async -> [Race] {
        do {
            for try await races in env.raceStore.observeRaces() {
                return races
            }
        } catch {}
        return []
    }

    /// Первая непустая строка ошибки из набора исходов → `toastMessage` (успех молчит).
    private func publishError(from results: [RefreshResult?]) {
        for result in results {
            if let result, let message = refreshErrorMessage(result) {
                toastMessage = message
                return
            }
        }
    }
}
