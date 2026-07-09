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

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    @ObservationIgnored private var innerTeamTask: Task<Void, Never>?
    /// Гонка, для которой уже отработал реактивный refresh (Launch B) — чтобы не перезапускать его на
    /// повторных эмиссиях той же гонки. `nil` при сбросе выбора → повторный выбор той же гонки снова
    /// дёрнет refresh.
    @ObservationIgnored private var lastReactiveRaceId: Int?

    init(env: AppEnvironment, now: @escaping () -> Date = { Date() }) {
        self.env = env
        self.now = now
    }

    // MARK: - Жизненный цикл

    /// Вызывается один раз из `.task` корневой вьюхи. Запускает подписку на выбранную команду и
    /// стартовый refresh (Launch A). Идемпотентен по подписке.
    func start() async {
        startSelectionObservationIfNeeded()
        await launchStartupRefresh()
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
        innerTeamTask?.cancel()
        selectedRaceId = selection?.raceId
        selectedTeamId = selection?.teamId

        guard let selection else {
            selectedTeamState = .none
            lastReactiveRaceId = nil
            return
        }

        selectedTeamState = .loading

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

    /// Фабрика модели флоу выбора гонки/команды. Держит `env` инкапсулированным (вьюхи не видят
    /// граф зависимостей): `TeamPickerModel` получает и `env`, и обратную ссылку на этот `AppModel`
    /// (для `confirm` → `selectTeam`). `now` прокидывается для тестируемого `today`.
    func makeTeamPickerModel(now: @escaping () -> Date = { Date() }) -> TeamPickerModel {
        TeamPickerModel(env: env, appModel: self, now: now)
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
        publishError(from: [await teams, await legend, await tags])
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
        publishError(from: [await races, await teams, await legend, await tags])
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
