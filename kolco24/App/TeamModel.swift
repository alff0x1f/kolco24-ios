//
//  TeamModel.swift
//  kolco24
//
//  `@Observable @MainActor`-модель вкладки «Команда». Порт ПОВЕДЕНИЯ (не структуры) роли
//  `Kolco24AppRoot` для экрана `ui/team/TeamScreen.kt`: сама выбранная команда приходит из
//  `AppModel.selectedTeamState`, а здесь живёт лишь локальный слой привязок чипов —
//  наблюдение `member_chip_bindings` для текущей команды (ключ — `numberInTeam`) и derived
//  `boundCount`/`allBound`, плюс отвязка (`deleteSlot`).
//
//  `bindings.count { … }` в Android — `members.count { bindings.containsKey(it.numberInTeam) }`:
//  считаются только слоты актуального ростера, поэтому derived-хелперы принимают `[TeamMemberItem]`
//  извне (ростер владеет `AppModel`, не эта модель).
//
//  `import SwiftUI` запрещён (grep-инвариант) — хватает `Observation`. Данные — из GRDB-observation
//  стора привязок; сеть тут не участвует (таблица локальная, на сервер не выгружается).
//

import Foundation
import Observation

@MainActor
@Observable
final class TeamModel {

    /// Привязки чипов текущей команды, ключ — `numberInTeam` слота участника.
    /// Пусто между `rebind` на новую команду и первой эмиссией её observation (stale-guard).
    private(set) var bindings: [Int: MemberChipBinding] = [:]
    /// Категории гонки выбранной команды — для строки «Категория X · N человек» на герой-карточке.
    private(set) var categories: [Category] = []

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private var bindingsTask: Task<Void, Never>?
    @ObservationIgnored private var categoriesTask: Task<Void, Never>?
    /// Команда/гонка активного наблюдения — для идемпотентности `rebind` на той же команде.
    @ObservationIgnored private var boundTeamId: Int?
    @ObservationIgnored private var boundRaceId: Int?

    init(env: AppEnvironment) {
        self.env = env
    }

    deinit {
        bindingsTask?.cancel()
        categoriesTask?.cancel()
    }

    // MARK: - Жизненный цикл

    /// Перепривязывает наблюдение привязок команды [teamId] и категорий её гонки [raceId] (или
    /// снимает оба при `nil`). Идемпотентно для той же пары. Stale-guard: до первой эмиссии новой
    /// команды в `bindings`/`categories` лежат данные прежней — очищаем синхронно (порт chips-guard
    /// из `MainActivity.kt`, где `collectAsState` не сбрасывается при смене ключа).
    func rebind(teamId: Int?, raceId: Int? = nil) {
        if teamId == boundTeamId, raceId == boundRaceId, bindingsTask != nil { return }
        bindingsTask?.cancel()
        categoriesTask?.cancel()
        bindings = [:]
        categories = []
        boundTeamId = teamId
        boundRaceId = raceId

        if let teamId {
            let observation = env.memberChipBindingStore.observeForTeam(teamId)
            bindingsTask = Task { [weak self] in
                do {
                    for try await rows in observation {
                        guard let self, !Task.isCancelled else { return }
                        self.bindings = Dictionary(uniqueKeysWithValues: rows.map { ($0.numberInTeam, $0) })
                    }
                } catch {}
            }
        }

        if let raceId {
            let observation = env.teamStore.observeCategoriesForRace(raceId)
            categoriesTask = Task { [weak self] in
                do {
                    for try await cats in observation {
                        guard let self, !Task.isCancelled else { return }
                        self.categories = cats
                    }
                } catch {}
            }
        }
    }

    /// Категория команды (для герой-строки), или `nil`, если не найдена/не задана.
    func category(for team: Team) -> Category? {
        guard let cid = team.categoryId else { return nil }
        return categories.first { $0.id == cid }
    }

    // MARK: - Derived (над актуальным ростером)

    /// Число участников ростера с привязанным чипом (только текущие слоты — устаревшие записи
    /// удалённых участников игнорируются). Делегирует общий Core-хелпер `boundCount(members:bindings:)`.
    func boundCount(members: [TeamMemberItem]) -> Int {
        kolco24.boundCount(members: members, bindings: bindings)
    }

    /// Все ли участники команды привязаны (герой-счётчик «N / total с чипом»). `total` — `team.ucount`.
    func allBound(members: [TeamMemberItem], total: Int) -> Bool {
        total > 0 && boundCount(members: members) >= total
    }

    /// Привязка слота [numberInTeam] или `nil`, если не привязан.
    func binding(for numberInTeam: Int) -> MemberChipBinding? {
        bindings[numberInTeam]
    }

    // MARK: - Действия

    /// Отвязка чипа от слота участника (порт `onUnbindMember` → `deleteSlot`). Ошибка молчалива —
    /// observation сам обновит `bindings` при успехе.
    func unbind(teamId: Int, numberInTeam: Int) async {
        try? await env.memberChipBindingStore.deleteSlot(teamId: teamId, numberInTeam: numberInTeam)
    }
}
