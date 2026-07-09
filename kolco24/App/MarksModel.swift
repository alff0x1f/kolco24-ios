//
//  MarksModel.swift
//  kolco24
//
//  `@Observable @MainActor`-модель вкладки «Отметки». Порт ПОВЕДЕНИЯ (не структуры) роли
//  `Kolco24AppRoot` для экрана `ui/marks/MarksScreen.kt`: держит сырые данные четырёх observation'ов
//  (взятия выбранной команды, КП гонки, агрегаты легенды, привязки чипов) и отдаёт derived-значения
//  через чистые функции этапа 2 (`Core/Marks/MarkMetrics`, `Core/Marks/MarksDisplay`).
//
//  Взятия/привязки привязаны к команде (`teamId`), КП/агрегаты — к гонке (`raceId`), поэтому
//  `rebind(teamId:raceId:)` перезапускает обе группы наблюдений. `costOf` берёт ЖИВУЮ цену КП из
//  легенды (id → текущий `cost`) с фолбэком на снимок в строке взятия — так СУММА «Отметок» держится
//  в шаге с «Легендой» после серверной правки цены (порт `checkpointCosts[id] ?: it.cost`).
//
//  `marksLoading` (порт `loading` из `MarksScreen.kt`): true, пока observation взятий не эмитировал
//  первую порцию для команды — подавляет мигание ложного empty-состояния на холодном старте. При
//  отсутствии команды загрузки нет (сразу `chooseTeam`).
//
//  `import SwiftUI` запрещён (grep-инвариант) — хватает `Observation`. Stale-guard (порт
//  `safeMarks`/`safeCheckpoints` из `MainActivity.kt`): между отменой старого observation и первой
//  эмиссией нового массивы очищаются синхронно, чтобы взятия прежней команды не участвовали в derived.
//

import Foundation
import Observation

@MainActor
@Observable
final class MarksModel {

    /// Взятия выбранной команды (newest-first, как отдаёт стор). Пусто между `rebind` и первой эмиссией.
    private(set) var marks: [Mark] = []
    /// КП текущей гонки — источник живой цены (`costOf`), цвета (`colorOf`) и locked-множества.
    private(set) var checkpoints: [Checkpoint] = []
    /// Агрегаты легенды текущей гонки (`total_cost`/`scoring_count`); `nil` до первой эмиссии.
    private(set) var legendMeta: LegendMeta?
    /// Привязки чипов текущей команды (ключ — `numberInTeam`) — для лестницы empty-состояний.
    private(set) var bindings: [Int: MemberChipBinding] = [:]
    /// Порт `loading`: true, пока observation взятий команды не эмитировал первую порцию. При `nil`-команде
    /// сразу `false` (нечего грузить — показываем `chooseTeam`).
    private(set) var marksLoading: Bool = false

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private var marksTask: Task<Void, Never>?
    @ObservationIgnored private var checkpointsTask: Task<Void, Never>?
    @ObservationIgnored private var legendMetaTask: Task<Void, Never>?
    @ObservationIgnored private var bindingsTask: Task<Void, Never>?
    /// Команда/гонка активных наблюдений — для идемпотентности `rebind` на той же паре.
    @ObservationIgnored private var boundTeamId: Int?
    @ObservationIgnored private var boundRaceId: Int?

    init(env: AppEnvironment) {
        self.env = env
    }

    deinit {
        marksTask?.cancel()
        checkpointsTask?.cancel()
        legendMetaTask?.cancel()
        bindingsTask?.cancel()
    }

    // MARK: - Жизненный цикл

    /// Перепривязывает наблюдения взятий/привязок команды [teamId] и КП/агрегатов гонки [raceId] (или
    /// снимает при `nil`). Идемпотентно для той же пары. Stale-guard: до первой эмиссии новой пары
    /// чистим массивы синхронно (порт `safeMarks`/`safeCheckpoints`, где `collectAsState` не сбрасывается
    /// при смене ключа). `marksLoading` взводится, только пока команда есть и observation ещё не эмитил.
    func rebind(teamId: Int?, raceId: Int?) {
        if teamId == boundTeamId, raceId == boundRaceId, marksTask != nil || checkpointsTask != nil {
            return
        }
        marksTask?.cancel()
        checkpointsTask?.cancel()
        legendMetaTask?.cancel()
        bindingsTask?.cancel()
        marks = []
        checkpoints = []
        legendMeta = nil
        bindings = [:]
        marksLoading = teamId != nil
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
                        self.marksLoading = false
                    }
                } catch {}
            }

            let bindingsObservation = env.memberChipBindingStore.observeForTeam(teamId)
            bindingsTask = Task { [weak self] in
                do {
                    for try await rows in bindingsObservation {
                        guard let self, !Task.isCancelled else { return }
                        self.bindings = Dictionary(uniqueKeysWithValues: rows.map { ($0.numberInTeam, $0) })
                    }
                } catch {}
            }
        }
    }

    // MARK: - Джойны КП (живая цена/цвет)

    /// КП текущей гонки по id — для резолверов `costOf`/`colorOf` и locked-множества.
    private var checkpointById: [Int: Checkpoint] {
        Dictionary(checkpoints.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Живая цена КП взятия: `checkpointCosts[id] ?? snapshot`. Locked-КП (`cost == nil`) даёт фолбэк
    /// на снимок строки. Порт `checkpointCosts[it.checkpointId] ?: it.cost`.
    private var costOf: (Mark) -> Int {
        let byId = checkpointById
        return { mark in byId[mark.checkpointId]?.cost ?? mark.cost }
    }

    /// Цвет КП взятия для заливки тайла (не используется существующим iOS-дизайном чип-тайла, но
    /// derived-слой держит его 1:1 с Android). Порт `parseCheckpointColor(checkpointColors[id] ?: "")`.
    private var colorOf: (Mark) -> CheckpointColor? {
        let byId = checkpointById
        return { mark in parseCheckpointColor(byId[mark.checkpointId]?.color ?? "") }
    }

    /// id ещё закрытых (locked) КП — их взятие даёт 0 в СУММУ до раскрытия (нотис hidden-taken).
    private var lockedIds: Set<Int> {
        var result = Set<Int>()
        for cp in checkpoints where cp.locked { result.insert(cp.id) }
        return result
    }

    // MARK: - Derived (чистые функции этапа 2)

    /// Тайлы сетки — один на complete-взятие, oldest-first (живая цена + цвет). Порт `marksToTiles`.
    var tiles: [MarkTile] { marksToTiles(marks, costOf: costOf, colorOf: colorOf) }

    /// ВЗЯТО (числитель) — число различных взятых scoring-КП (cost>0 по живой цене). Порт `takenPointCount`.
    var takenKp: Int { takenPointCount(marks, costOf: costOf) }

    /// Знаменатель ВЗЯТО — `scoring_count` из `legend_meta` (0 до эмиссии; вьюха скрывает «/0»).
    var totalKp: Int { legendMeta?.scoringCount ?? 0 }

    /// СУММА (числитель) — сумма живых цен различных взятых КП. Порт `totalScore(marks, costOf)`.
    var takenScore: Int { totalScore(marks, costOf: costOf) }

    /// Знаменатель СУММЫ — `total_cost` из `legend_meta` (сумма ВСЕХ КП, включая locked).
    var totalCost: Int { legendMeta?.totalCost ?? 0 }

    /// Токены «взято, баллы неизвестны» (locked-КП, взятые командой) — нотис под метриками. Порт
    /// `hiddenTakenTokens`.
    var hiddenTakenTokens: [String] { kolco24.hiddenTakenTokens(marks, lockedIds: lockedIds) }

    // MARK: - Лестница empty-состояний

    /// Число участников ростера с привязанным чипом (только текущие слоты — устаревшие записи
    /// удалённых участников игнорируются). Совпадает с логикой `TeamModel.boundCount`.
    func boundCount(members: [TeamMemberItem]) -> Int {
        members.reduce(0) { $0 + (bindings[$1.numberInTeam] != nil ? 1 : 0) }
    }

    /// Состояние пустого экрана: `loading` подавляет мигание; нет команды → `chooseTeam`; не все чипы
    /// привязаны → `bindChips`; иначе → `ready`. Порт ветвления `MarksEmpty` (NFC-ветки — этап 5).
    func emptyState(hasTeam: Bool, members: [TeamMemberItem]) -> MarksEmptyState {
        marksEmptyState(
            loading: marksLoading,
            hasTeam: hasTeam,
            memberCount: members.count,
            boundCount: boundCount(members: members)
        )
    }
}
