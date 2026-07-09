//
//  TeamPickerModel.swift
//  kolco24
//
//  `@Observable @MainActor`-модель флоу выбора гонки/команды. Порт ПОВЕДЕНИЯ (не структуры) двух
//  Android-экранов: `CompPickerScreen.kt` (шаг 1 — список гонок) и `TeamPickerScreen.kt` (шаг 2 —
//  команды одной гонки). В Android состояния экранов — `remember`/`rememberSaveable` внутри
//  composable'ов + `onRaceSelected`-хендлер в `MainActivity.kt`; здесь всё собрано в одну модель,
//  общую для NavigationStack-флоу (`.fullScreenCover`).
//
//  Чистая derived-логика (`splitRaces`/`filterTeams`/`raceStatusPill`/`teamToken`/…) переиспользуется
//  из `Core/Team/TeamPickerLogic.swift`. `import SwiftUI` запрещён (grep-инвариант) — хватает
//  `Observation`. Данные — из GRDB-observation'ов сторов; refresh — через репозитории (всё `.cloud`).
//

import Foundation
import Observation

@MainActor
@Observable
final class TeamPickerModel {

    /// Исход `refreshTeams` для выбранной гонки → UI загрузки/ошибки. Порт `enum PickerLoad`
    /// из `TeamPickerScreen.kt` (`Loading/Loaded/Offline/HttpError/Forbidden`).
    enum PickerLoad: Equatable {
        case loading
        case loaded
        case offline
        case forbidden
        case httpError(Int)
    }

    /// Секция команд одной категории (сортировка `sortOrder`; `nil` — «без категории», всегда в конце).
    struct TeamSection: Identifiable {
        let category: Category?
        let teams: [Team]
        var id: Int { category?.id ?? -1 }
    }

    // MARK: - Наблюдаемое состояние
    private(set) var races: [Race] = []
    private(set) var teams: [Team] = []
    private(set) var categories: [Category] = []
    /// `true` после первой эмиссии teams-observation для текущей гонки — подавляет мигание пустого/stale
    /// списка между переключением гонки и первой эмиссией (порт `teamsLoaded` из `TeamPickerScreen.kt`).
    private(set) var teamsLoaded = false
    private(set) var load: PickerLoad = .loading
    /// Гонка, чьи команды сейчас просматриваются (шаг 2). Отдельно от committed-выбора в `AppModel`.
    private(set) var pickerRaceId: Int?
    /// Строка поиска команд (`.searchable`). Порт `query`-state из `TeamPickerScreen.kt`.
    var searchQuery: String = ""

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private let appModel: AppModel
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var racesTask: Task<Void, Never>?
    @ObservationIgnored private var teamsTask: Task<Void, Never>?
    @ObservationIgnored private var categoriesTask: Task<Void, Never>?

    init(env: AppEnvironment, appModel: AppModel, now: @escaping () -> Date = { Date() }) {
        self.env = env
        self.appModel = appModel
        self.now = now
    }

    deinit {
        racesTask?.cancel()
        teamsTask?.cancel()
        categoriesTask?.cancel()
    }

    // MARK: - Derived (через TeamPickerLogic)

    /// Сегодняшняя дата ISO-строкой — для `splitRaces`/`raceStatusPill`.
    var today: String { todayIso(now: now()) }

    /// Гонки, разбитые на текущие/архив (`effectiveEnd >= today`).
    var split: SplitRaces { splitRaces(races, today: today) }

    /// Committed-выбор из `AppModel` — подсветка «текущей» гонки/команды в списках.
    var selectedRaceId: Int? { appModel.selectedRaceId }
    var selectedTeamId: Int? { appModel.selectedTeamId }

    /// Гонка, чьи команды сейчас показываются (для карточки контекста в шаге 2).
    var pickerRace: Race? {
        guard let id = pickerRaceId else { return nil }
        return races.first { $0.id == id }
    }

    /// Отфильтрованные по `searchQuery` команды (имя/номер, регистронезависимо).
    var filteredTeams: [Team] { filterTeams(teams, query: searchQuery) }

    /// Категория команды (или `nil`), по `categoryId`.
    func category(for team: Team) -> Category? {
        guard let cid = team.categoryId else { return nil }
        return categories.first { $0.id == cid }
    }

    /// Отфильтрованные команды, сгруппированные в секции по категориям (сортировка `sortOrder`);
    /// команды без известной категории — в трейлинг-секцию `category == nil`. iOS-адаптация
    /// (в Android — плоский список; здесь `List` с секциями).
    var sections: [TeamSection] {
        let visible = filteredTeams
        var result: [TeamSection] = []
        for cat in categories.sorted(by: { $0.sortOrder < $1.sortOrder }) {
            let members = visible.filter { $0.categoryId == cat.id }
            if !members.isEmpty { result.append(TeamSection(category: cat, teams: members)) }
        }
        let knownIds = Set(categories.map { $0.id })
        let uncategorized = visible.filter { team in
            team.categoryId.map { !knownIds.contains($0) } ?? true
        }
        if !uncategorized.isEmpty { result.append(TeamSection(category: nil, teams: uncategorized)) }
        return result
    }

    // MARK: - Жизненный цикл

    /// Запускает наблюдение за списком гонок (шаг 1). Идемпотентно.
    func start() {
        guard racesTask == nil else { return }
        let observation = env.raceStore.observeRaces()
        racesTask = Task { [weak self] in
            do {
                for try await races in observation {
                    guard let self, !Task.isCancelled else { return }
                    self.races = races
                }
            } catch {}
        }
    }

    // MARK: - Действия (порт CompPicker / onRaceSelected / confirm)

    /// Открытие шага 1 / pull-to-refresh: одноразовый ETag-guarded `refreshRaces`. Список гонок
    /// приходит через observation; ошибка тут молчалива (кэш остаётся, старт-refresh уже покрывает).
    func openedCompPicker() async {
        _ = try? await env.raceRepository.refreshRaces()
    }

    /// Выбор гонки (шаг 1 → шаг 2). Порт `onRaceSelected` из `MainActivity.kt`: перепривязывает
    /// observation команд/категорий на новую гонку (сброс stale-строк прежней), фоном прогревает
    /// легенду (best-effort) и обновляет команды, мапя исход в `load`.
    func raceSelected(_ raceId: Int) async {
        pickerRaceId = raceId
        searchQuery = ""
        load = .loading
        rebindTeams(raceId: raceId)
        // Префетч легенды — best-effort, результат игнорируется (порт двух корутин `onRaceSelected`).
        Task { [weak self] in _ = try? await self?.env.legendRepository.refreshLegend(raceId) }
        let result = try? await env.teamRepository.refreshTeams(raceId)
        load = pickerLoad(from: result)
    }

    /// Pull-to-refresh шага 2: перезапрос команд текущей просматриваемой гонки.
    func refreshTeams() async {
        guard let raceId = pickerRaceId else { return }
        let result = try? await env.teamRepository.refreshTeams(raceId)
        load = pickerLoad(from: result)
    }

    /// Подтверждение (шаг 3): персистит выбранную команду через `AppModel` — реактивный блок
    /// `AppModel` сам подтянет данные вкладок. Порт `selectTeam` из `MainActivity.kt`.
    func confirm(raceId: Int, teamId: Int) async {
        await appModel.selectTeam(raceId: raceId, teamId: teamId)
    }

    // MARK: - Внутреннее

    private func rebindTeams(raceId: Int) {
        teamsTask?.cancel()
        categoriesTask?.cancel()
        // Stale-guard: до первой эмиссии новой гонки в массивах лежат строки прежней — чистим.
        teams = []
        categories = []
        teamsLoaded = false

        let teamsObs = env.teamStore.observeTeamsForRace(raceId)
        teamsTask = Task { [weak self] in
            do {
                for try await teams in teamsObs {
                    guard let self, !Task.isCancelled else { return }
                    self.teams = teams
                    self.teamsLoaded = true
                }
            } catch {}
        }
        let catsObs = env.teamStore.observeCategoriesForRace(raceId)
        categoriesTask = Task { [weak self] in
            do {
                for try await cats in catsObs {
                    guard let self, !Task.isCancelled else { return }
                    self.categories = cats
                }
            } catch {}
        }
    }

    /// Порт маппинга `RefreshResult → PickerLoad` из `TeamPickerScreen.kt`. `nil` (бросок репозитория,
    /// на практике только тяжёлая ошибка БД) трактуется как offline.
    private func pickerLoad(from result: RefreshResult?) -> PickerLoad {
        switch result {
        case .updated, .notModified, .skipped: return .loaded
        case .offline, .none: return .offline
        case .forbidden: return .forbidden
        case .httpError(let code): return .httpError(code)
        }
    }
}
