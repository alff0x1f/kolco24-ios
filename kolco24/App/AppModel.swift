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

    /// Идёт ли сейчас вход/выход LAN-режима (этап 9). App-scoped (переживает закрытие шита настроек):
    /// спиннер тумблера читает это. Гард от двойного входа — `guard !localModeBusy` в `toggleLocalMode`.
    var localModeBusy: Bool = false

    /// Текущий статус доверенных часов (этап 11). Единственный потребитель `TrustedClock.statusUpdates`:
    /// `AppModel` держит одну подписку и публикует значение сюда, все баннер-поверхности читают свойство
    /// (глобальный над вкладками, плашка в скан-оверлее, судейский скан). `@Observable` → перекраска
    /// баннеров мгновенна.
    private(set) var clockStatus: ClockStatus = .noSync

    /// Текущий режим темы (этап 9). Сид из `ThemePreference`; сеттер персистит через стор. Корневая
    /// вьюха маппит в `.preferredColorScheme`. `@Observable` трекает stored-property → перекраска мгновенна.
    var themeMode: ThemeMode {
        didSet { env.themePreference.setMode(themeMode) }
    }

    /// Единый рекордер GPS-трека (этап 8): один экземпляр на весь жизненный цикл приложения (переживает
    /// уходы с таба). Вьюха «Команда» держит его напрямую (`@Observable` — SwiftUI трекает
    /// `state`/`pointCount`); смена/сброс выбранной команды останавливает живую запись (см. `handleSelection`).
    let trackRecorder: TrackRecorder

    /// Интервал повторной попытки дренажа выгрузки (`UPLOAD_RETRY_INTERVAL_MS`, имя как в Kotlin).
    /// Инжектится, чтобы тесты не ждали реальные 5 минут.
    static let uploadRetryIntervalMs = 300_000

    @ObservationIgnored private let env: AppEnvironment
    /// Оркестратор LAN-режима (этап 9): источник `sourceFor`, проба/вход/выход, pin-aware `refreshAll`.
    @ObservationIgnored private let coordinator: SyncCoordinator
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let uploadRetryIntervalMs: Int
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var innerTeamTask: Task<Void, Never>?
    /// 5-минутный foreground-цикл дренажа выгрузки (порт таймера `MainActivity.kt` L167/589–597).
    /// Пересоздаётся `scenePhaseChanged(isActive:)` (аналог `repeatOnLifecycle(STARTED)`).
    @ObservationIgnored private var uploadLoopTask: Task<Void, Never>?
    /// Подписка на `TrustedClock.statusUpdates` (этап 11). Хранится, чтобы гардить повторный вход:
    /// `statusUpdates` — одно-итераторный `AsyncStream`, второй `for await` = runtime fault (корневой
    /// `.task` теоретически может перезапуститься). Идиома `startSelectionObservationIfNeeded`.
    @ObservationIgnored private var clockStatusTask: Task<Void, Never>?
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
        self.coordinator = env.syncCoordinator
        self.themeMode = env.themePreference.mode
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
        startClockStatusObservationIfNeeded()
        startUploadLoop()
        sweepOrphanPhotoDirs()
        await launchStartupRefresh()
    }

    /// Единственный потребитель `TrustedClock.statusUpdates` (этап 11): `for await` публикует каждое
    /// обновление в `clockStatus`. Начальное значение приходит первой же итерацией — `statusUpdates`
    /// это `bufferingNewest(1)`-стрим, засеянный текущим статусом в `TrustedClock.init`, поэтому
    /// отдельное `await clock.status` перед циклом не нужно. Идемпотентен по подписке
    /// (`guard clockStatusTask == nil`) — `statusUpdates` одно-итераторный, повторный `for await`
    /// уронил бы рантайм. Отменяется вместе с моделью.
    private func startClockStatusObservationIfNeeded() {
        guard clockStatusTask == nil else { return }
        let clock = env.trustedClock
        clockStatusTask = Task { [weak self] in
            for await status in clock.statusUpdates {
                guard let self else { return }
                self.clockStatus = status
            }
        }
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
        let judgeRepo = env.judgeScanUploadRepository
        let intervalMs = uploadRetryIntervalMs
        uploadLoopTask = Task {
            while !Task.isCancelled {
                await repo.uploadAllPending()
                // Этап 8: тем же таймером досылаем и точки трека (обе цели, self-heal).
                await trackRepo.uploadAllPending()
                // Этап 10: и судейские пики старта/финиша (обе цели, self-heal).
                await judgeRepo.uploadAllPending()
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
        // Этап 10: и судейских пиков (застрявших под прежней гонкой) — тем же оппортунистическим дренажом.
        let judgeRepo = env.judgeScanUploadRepository
        Task { await judgeRepo.uploadAllPending() }

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

    // MARK: - LAN-режим (этап 9)

    /// Тумблер «Локальный сервер»: вход (`enterLocalMode`) или выход (`exitLocalMode`) LAN-режима.
    /// Fire-and-forget `Task`, захватывающий КООРДИНАТОР (не `self`) — оркестрация переживает закрытие
    /// шита настроек. `localModeBusy` (спиннер) гарантированно сбрасывается на возврате координатора
    /// через `defer`, иначе спиннер бы залип; исход → русский тост. Гард `!localModeBusy` — от двойного
    /// входа (сам актор сериализует, но UI не должен слать вторую пробу поверх активной).
    func toggleLocalMode(_ on: Bool) {
        guard !localModeBusy else { return }
        localModeBusy = true
        let coordinator = self.coordinator
        Task { @MainActor [weak self] in
            defer { self?.localModeBusy = false }
            let outcome = on ? await coordinator.enterLocalMode() : await coordinator.exitLocalMode()
            self?.toastMessage = AppModel.localModeToast(outcome)
        }
    }

    /// Русский тост по исходу LAN-переключения (Technical Details, таблица тостов). `internal` (не
    /// `private`) — таблицу маппинга исход→строка напрямую покрывает `AppModelTests`.
    static func localModeToast(_ outcome: LocalModeOutcome) -> String {
        switch outcome {
        case let .pinnedUntil(expiresAtMs, dataStale):
            return localModeUntilLabel(expiresAtMs: expiresAtMs) + (dataStale ? " (данные не обновлены)" : "")
        case .localNoPin, .cloudUpdated:
            return "Обновлено из интернета"
        case .localUnreachable:
            return "Локальный сервер недоступен"
        case .offline:
            return "Нет сети"
        case .noRace:
            return "Гонка не выбрана"
        }
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

    /// Фабрика модели вкладки «Карта». Привязывается к ТЕКУЩЕМУ скоупу выбора
    /// (`selectedRaceId`/`selectedTeamId`); `nil` без выбранной команды (вьюха тогда зовёт
    /// `onChooseTeam`). Держит `env` инкапсулированным; ошибка скачивания подложки идёт тостом в этот
    /// `AppModel` (`toastMessage`).
    func makeMapModel() -> MapModel? {
        guard let raceId = selectedRaceId, let teamId = selectedTeamId else { return nil }
        let model = MapModel(env: env, onToast: { [weak self] message in self?.toastMessage = message })
        model.rebind(teamId: teamId, raceId: raceId)
        return model
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

    /// Фабрика модели экрана «Настройки» (этап 9). Привязывается к ТЕКУЩЕМУ скоупу выбора
    /// (`selectedRaceId`/`selectedTeamId`) — шит открывается для выбранной команды. Держит обратную
    /// ссылку на этот `AppModel` (тема/busy/тосты/сброс команды — app-scoped). Версия — из `Bundle.main`
    /// (`CFBundleShortVersionString`/`CFBundleVersion`); тесты инжектят свои значения напрямую в `init`.
    func makeSettingsModel() -> SettingsModel {
        SettingsModel(
            env: env,
            appModel: self,
            raceId: selectedRaceId,
            teamId: selectedTeamId,
            versionName: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            versionCode: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        )
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

    /// Фабрика хост-редьюсера судейского экрана «Отметка старта/финиша» (этап 10). `raceId` — гонка
    /// ВЫБРАННОЙ команды (судейская станция сканит все команды одной гонки); возвращает `nil`, когда
    /// команда не выбрана (гонка неизвестна). Держит `env` инкапсулированным. Прод-сканер `NfcChipScanner`
    /// (из `Nfc/`) инстанцируется здесь (App-слой в одном модуле — CoreNFC не импортируется); семпл
    /// доверенного времени берётся ДО чтения чипа синхронным мостом к актору-часам, `shouldRestart`
    /// читает потокобезопасный `liveness` (§60-с рестарт, как у скан/bind-флоу).
    func makeJudgeScanModel(eventType: String) -> JudgeScanModel? {
        guard let raceId = selectedRaceId else { return nil }
        let model = JudgeScanModel(
            raceId: raceId,
            eventType: eventType,
            judgeScanStore: env.judgeScanStore,
            repository: env.judgeScanUploadRepository,
            memberTagsRepository: env.memberTagsRepository,
            feedback: env.feedback,
            installId: env.installId
        )
        let clock = env.trustedClock
        let liveness = model.liveness
        let scanner = NfcChipScanner(
            sampleNow: { AppModel.syncSample(clock) },
            shouldRestart: { liveness.isAlive }
        )
        model.attachProductionScanner(scanner)
        return model
    }

    /// Фабрика хост-редьюсера read-only проверки КП-чипов «Проверка чипов КП» (этап 10). `raceId` —
    /// гонка ВЫБРАННОЙ команды; возвращает `nil`, когда команда не выбрана (легенда неизвестна).
    /// Полностью оффлайн (легенда из сторов, без сети). Прод-сканер `NfcChipScanner` инстанцируется
    /// здесь (App-слой в одном модуле — CoreNFC не импортируется), как у скан/судейского флоу.
    func makeChipCheckModel() -> ChipCheckModel? {
        guard let raceId = selectedRaceId else { return nil }
        let model = ChipCheckModel(
            raceId: raceId,
            tagStore: env.tagStore,
            checkpointStore: env.checkpointStore,
            feedback: env.feedback
        )
        let clock = env.trustedClock
        let liveness = model.liveness
        let scanner = NfcChipScanner(
            sampleNow: { AppModel.syncSample(clock) },
            shouldRestart: { liveness.isAlive }
        )
        model.attachProductionScanner(scanner)
        return model
    }

    /// Фабрика хост-редьюсера read-only проверки браслетов «Проверка браслетов» (этап 10). `raceId` —
    /// гонка ВЫБРАННОЙ команды; возвращает `nil`, когда команда не выбрана (пул неизвестен). Полностью
    /// оффлайн (пул `member_tags` из стора, без сети). Прод-сканер инстанцируется здесь.
    func makeMemberChipCheckModel() -> MemberChipCheckModel? {
        guard let raceId = selectedRaceId else { return nil }
        let model = MemberChipCheckModel(
            raceId: raceId,
            memberTagStore: env.memberTagStore,
            feedback: env.feedback
        )
        let clock = env.trustedClock
        let liveness = model.liveness
        let scanner = NfcChipScanner(
            sampleNow: { AppModel.syncSample(clock) },
            shouldRestart: { liveness.isAlive }
        )
        model.attachProductionScanner(scanner)
        return model
    }

    /// Фабрика хост-редьюсера провижининга «Привязка чипов» (этап 10). `raceId` — гонка ВЫБРАННОЙ
    /// команды; возвращает `nil`, когда команда не выбрана (легенда/гонка неизвестна). `bindTag` бьёт
    /// cloud-клиент (замыкание графа); `onUnauthorized` при 401 роняет admin-сессию (форма логина).
    /// Прод-сканер `NfcChipScanner` инстанцируется здесь (App-слой в одном модуле — CoreNFC не
    /// импортируется) и умеет pending-write (реализует `ProvisioningScanning`).
    func makeProvisioningModel() -> ProvisioningModel? {
        guard let raceId = selectedRaceId else { return nil }
        let repo = env.adminAuthRepository
        let model = ProvisioningModel(
            raceId: raceId,
            checkpointStore: env.checkpointStore,
            tagStore: env.tagStore,
            bindTag: env.bindTag,
            onUnauthorized: { repo.onUnauthorized() },
            feedback: env.feedback
        )
        let clock = env.trustedClock
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

    // MARK: - Админ-сессия (этап 10)

    /// Текущая admin-сессия (синхронное чтение держателя) — для сида ветвления `AdminHomeView`
    /// и сабтайтла ряда «Администратор». Держит `env` инкапсулированным.
    var currentAdminSession: AdminSession { env.adminSessionHolder.session }

    /// Поток обновлений admin-сессии для `AdminHomeView` (ветвление форма/меню + реакция на
    /// 401-разлогин). `AsyncStream` держателя мультиконсумерный (свежий стрим на каждую подписку,
    /// сидированный текущим значением). Сабтайтл ряда в `SettingsModel` тем не менее читает сессию
    /// синхронно — не из-за одноконсумерности, а потому что шит настроек и `fullScreenCover` админа
    /// взаимоисключающи: сессия не меняется, пока ряд «Администратор» на экране.
    var adminSessionUpdates: AsyncStream<AdminSession> { env.adminSessionHolder.updates }

    /// Вход организатора: делегирует `AdminAuthRepository.login` (persist + публикация сессии на успехе).
    func adminLogin(email: String, password: String) async -> LoginOutcome {
        await env.adminAuthRepository.login(email: email, password: password)
    }

    /// Выход организатора: `AdminAuthRepository.logout` (best-effort сеть, локальная сессия чистится всегда).
    func adminLogout() async {
        await env.adminAuthRepository.logout()
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
        // Этап 9: прогрев с источника, назначенного координатором (LAN, если гонка запинена).
        let source = coordinator.sourceFor(nearest)
        async let teams = try? env.teamRepository.refreshTeams(nearest, source: source)
        async let legend = try? env.legendRepository.refreshLegend(nearest, source: source)
        async let tags = try? env.memberTagsRepository.refreshMemberTags(nearest, source: source)
        _ = await (teams, legend, tags)
    }

    /// Launch B: реактивный refresh при смене гонки. Ошибка → `toastMessage`.
    private func reactiveRefresh(raceId: Int) async {
        // Этап 9: под пином сперва heartbeat LAN (renew / детекция handback), затем fan-out через
        // ПЕРЕЧИТАННЫЙ источник — проба могла только что снять пин (handback на cloud).
        if coordinator.sourceFor(raceId) == .local {
            await coordinator.probeLocalAndRenew(raceId)
        }
        let source = coordinator.sourceFor(raceId)
        async let teams = try? env.teamRepository.refreshTeams(raceId, source: source)
        async let legend = try? env.legendRepository.refreshLegend(raceId, source: source)
        async let tags = try? env.memberTagsRepository.refreshMemberTags(raceId, source: source)
        let results = [await teams, await legend, await tags]
        // Stale-guard: гонка могла смениться, пока fan-out был в полёте. В Android этот блок живёт
        // под `collectLatest` — смена команды отменяет in-flight refresh, поэтому его ошибка тоста
        // не показывает; здесь Task не отменяется, гасим stale-тост явной проверкой.
        guard selectedRaceId == raceId else { return }
        publishError(from: results)
    }

    /// Pull-to-refresh «Легенды»: точечный refresh легенды гонки [raceId], ошибка → `toastMessage`.
    func refreshLegend(raceId: Int) async {
        // Этап 9: с источника, назначенного координатором (LAN, если гонка запинена).
        let result = try? await env.legendRepository.refreshLegend(raceId, source: coordinator.sourceFor(raceId))
        publishError(from: [result])
    }

    /// Pull-to-refresh «Команды»: под пином — проба LAN + fan-out с перечитанным источником (делегируется
    /// координатору), иначе — cloud fan-out. Тост — свёрнутый `RefreshResult`. Без выбора — только races.
    func refreshAll() async {
        guard let raceId = selectedRaceId else {
            let result = try? await env.raceRepository.refreshRaces()
            publishError(from: [result])
            return
        }
        let result: RefreshResult? = await coordinator.refreshAll(raceId)
        // Stale-guard (см. `reactiveRefresh`): пользователь мог сменить гонку за время fan-out.
        guard selectedRaceId == raceId else { return }
        publishError(from: [result])
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

/// «Локальный режим до HH:mm» (локальная таймзона) из epoch-ms истечения lease — общий формат
/// для тоста LAN-переключения (`AppModel.localModeToast`) и сабтайтла ряда LAN в `SettingsModel`.
/// Free-функция App-слоя (Foundation-only) — без дублирования формата в двух местах.
func localModeUntilLabel(expiresAtMs: Int64) -> String {
    let time = Date(timeIntervalSince1970: Double(expiresAtMs) / 1000)
        .formatted(.dateTime.hour().minute())
    return "Локальный режим до \(time)"
}
