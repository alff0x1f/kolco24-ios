//
//  LegendModel.swift
//  kolco24
//
//  `@Observable @MainActor`-модель вкладки «Легенда». Порт ПОВЕДЕНИЯ (не структуры) роли
//  `Kolco24AppRoot` для экрана `ui/legend/LegendScreen.kt`: держит сырые данные трёх observation'ов
//  (КП гонки, агрегаты легенды, взятия выбранной команды) и отдаёт derived-значения через чистые
//  функции этапа 2 (`Core/Legend/LegendDisplay`, `Core/Marks/MarkMetrics`).
//
//  КП/агрегаты привязаны к гонке (`raceId`), «взято» — к команде (`marks` через `takenPoints`);
//  поэтому `rebind(teamId:raceId:)` перезапускает обе группы наблюдений. «Взято» team-scoped и не
//  пишется на строку КП (общий на гонку КП иначе протёк бы прогрессом одной команды на другую).
//
//  Прогресс ScoreCard считается как `takenScore/totalCost` — знаменатель берётся из `legend_meta`
//  (сумма ВСЕХ КП, включая locked, чью цену клиент не видит), а не суммируется по строкам КП
//  клиентом, иначе бар доходил бы до 100% раньше времени (порт комментария к `takenScore`).
//
//  `import SwiftUI` запрещён (grep-инвариант) — хватает `Observation`. Stale-guard (порт
//  `safeCheckpoints`/`safeMarks` из `MainActivity.kt`): между отменой старого observation и первой
//  эмиссией нового массивы очищаются синхронно, чтобы строки прежней гонки/команды не участвовали в
//  derived.
//

import Foundation
import Observation

@MainActor
@Observable
final class LegendModel {

    /// КП текущей гонки (порядок стора: `number, id`). Пусто между `rebind` и первой эмиссией.
    private(set) var checkpoints: [Checkpoint] = []
    /// Агрегаты легенды текущей гонки (`total_cost`/`scoring_count`); `nil` до первой эмиссии.
    private(set) var legendMeta: LegendMeta?
    /// Взятия выбранной команды — источник `takenIds` (team-scoped, не флаг на КП).
    private(set) var marks: [Mark] = []

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private var checkpointsTask: Task<Void, Never>?
    @ObservationIgnored private var legendMetaTask: Task<Void, Never>?
    @ObservationIgnored private var marksTask: Task<Void, Never>?
    /// Команда/гонка активных наблюдений — для идемпотентности `rebind` на той же паре.
    @ObservationIgnored private var boundTeamId: Int?
    @ObservationIgnored private var boundRaceId: Int?

    init(env: AppEnvironment) {
        self.env = env
    }

    deinit {
        checkpointsTask?.cancel()
        legendMetaTask?.cancel()
        marksTask?.cancel()
    }

    // MARK: - Жизненный цикл

    /// Перепривязывает наблюдения КП/агрегатов гонки [raceId] и взятий команды [teamId] (или снимает
    /// при `nil`). Идемпотентно для той же пары. Stale-guard: до первой эмиссии новой пары чистим
    /// массивы синхронно (порт `safeCheckpoints`/`safeMarks`, где `collectAsState` не сбрасывается при
    /// смене ключа).
    func rebind(teamId: Int?, raceId: Int?) {
        if teamId == boundTeamId, raceId == boundRaceId, checkpointsTask != nil || marksTask != nil {
            return
        }
        checkpointsTask?.cancel()
        legendMetaTask?.cancel()
        marksTask?.cancel()
        checkpoints = []
        legendMeta = nil
        marks = []
        boundTeamId = teamId
        boundRaceId = raceId

        if let raceId {
            let cpObservation = env.checkpointStore.observeCheckpointsForRace(raceId)
            checkpointsTask = Task { [weak self] in
                do {
                    for try await rows in cpObservation {
                        guard let self, !Task.isCancelled else { return }
                        self.checkpoints = rows
                    }
                } catch {}
            }

            let metaObservation = env.legendMetaStore.observeForRace(raceId)
            legendMetaTask = Task { [weak self] in
                do {
                    for try await meta in metaObservation {
                        guard let self, !Task.isCancelled else { return }
                        self.legendMeta = meta
                    }
                } catch {}
            }
        }

        if let teamId {
            let marksObservation = env.markStore.observeForTeam(teamId)
            marksTask = Task { [weak self] in
                do {
                    for try await rows in marksObservation {
                        guard let self, !Task.isCancelled else { return }
                        self.marks = rows
                    }
                } catch {}
            }
        }
    }

    // MARK: - Derived (чистые функции этапа 2)

    /// Множество id КП, зачтённых выбранной командой (из её complete-взятий).
    var takenIds: Set<Int> { takenPoints(marks) }

    /// Число КП списка, взятых командой (ВСЕ КП, включая технические cost 0 — как чипы/список).
    var takenCount: Int { checkpoints.reduce(0) { $0 + (takenIds.contains($1.id) ? 1 : 0) } }

    /// Всего КП в списке.
    var totalCount: Int { checkpoints.count }

    /// Число взятых scoring-КП (числитель «N/M КП» ScoreCard) — locked-КП scoring по определению.
    var takenScoring: Int {
        let taken = takenIds
        return checkpoints.reduce(0) { $0 + (taken.contains($1.id) && $1.isScoring ? 1 : 0) }
    }

    /// Знаменатель «N/M КП» — `scoring_count` из `legend_meta` (0 до первой эмиссии/пока сервер не
    /// прислал; вьюха скрывает «/0»).
    var scoringCount: Int { legendMeta?.scoringCount ?? 0 }

    /// Числитель прогресса — сумма ИЗВЕСТНЫХ цен взятых КП (взятие locked-КП раскрывает цену). Порт
    /// `checkpoints.filter { id in takenIds }.mapNotNull { cost }.sum()`.
    var takenScore: Int {
        let taken = takenIds
        return checkpoints.reduce(0) { acc, cp in
            (taken.contains(cp.id) ? (cp.cost ?? 0) : 0) + acc
        }
    }

    /// Знаменатель прогресса — `total_cost` из `legend_meta` (сумма ВСЕХ КП, включая locked). Не
    /// суммируется клиентом по строкам (locked скрывает цену).
    var totalScore: Int { legendMeta?.totalCost ?? 0 }

    /// Прогресс ScoreCard `takenScore/totalScore` в `0...1`; `0` при пустом знаменателе.
    var progress: Double {
        totalScore > 0 ? Double(takenScore) / Double(totalScore) : 0
    }

    /// Число ещё закрытых (locked) КП — для карточки «Скрыто N КП».
    var lockedCount: Int { checkpoints.reduce(0) { $0 + ($1.locked ? 1 : 0) } }

    /// Видимые КП с учётом фильтра «только не взятые» (порт `showOnlyOpen`); порядок стора сохранён.
    func visibleCheckpoints(showOnlyOpen: Bool) -> [Checkpoint] {
        guard showOnlyOpen else { return checkpoints }
        let taken = takenIds
        return checkpoints.filter { !taken.contains($0.id) }
    }
}
