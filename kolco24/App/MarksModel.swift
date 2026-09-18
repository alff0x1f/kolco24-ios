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
//  первую порцию для команды — вьюха на это время не рисует ничего, подавляя мигание чек-листа на
//  холодном старте. При отсутствии команды загрузки нет (чек-лист показывается сразу).
//
//  Сверх наблюдений модель собирает чек-лист готовности к старту (`readiness(team:members:clock:)`,
//  ядро — `Core/Readiness/ReadinessChecklist`). Геостатус, Low Power Mode и наличие файла подложки —
//  **синхронный опрос** замыканий `env` (`refreshDeviceState()`), а не observation: они меняются вне
//  приложения (Настройки iOS) или на другой вкладке, БД о них ничего не знает. `mapUrl` гонки читается
//  из БД один раз в `rebind`, а вот существование файла перечитывается на каждом опросе — `rebind`
//  рано выходит на неизменённой паре, а вкладки в `TabView` живут вечно, иначе пункт застрял бы в
//  «карта не скачана» после возврата с вкладки «Карта» (тот же приём, что `MapModel.refreshAvailability`).
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

    /// Доступность оффлайн-подложки для чек-листа: `.notApplicable`, пока у гонки нет `mapUrl`.
    /// Пересчитывается из `mapUrl` (БД, один раз в `rebind`) + `env.mapFileExists` (каждый опрос).
    private(set) var mapReadiness: MapReadiness = .notApplicable
    /// Трёхзначный геостатус последнего опроса устройства.
    private(set) var locationAuth: LocationAuthorization = .granted
    /// «Дана примерная локация» последнего опроса устройства.
    private(set) var isReducedAccuracy: Bool = false
    /// Low Power Mode последнего опроса устройства.
    private(set) var lowPowerMode: Bool = false

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private var marksTask: Task<Void, Never>?
    @ObservationIgnored private var checkpointsTask: Task<Void, Never>?
    @ObservationIgnored private var legendMetaTask: Task<Void, Never>?
    @ObservationIgnored private var bindingsTask: Task<Void, Never>?
    @ObservationIgnored private var mapReadinessTask: Task<Void, Never>?
    /// `mapUrl` текущей гонки (one-shot чтение в `rebind`); пусто/`nil` → пункта карты нет.
    @ObservationIgnored private var mapUrl: String?
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
        mapReadinessTask?.cancel()
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
        mapReadinessTask?.cancel()
        marks = []
        checkpoints = []
        legendMeta = nil
        bindings = [:]
        // Stale-guard чек-листа: подложка прежней гонки не должна дожить до эмиссии новой.
        mapUrl = nil
        mapReadiness = .notApplicable
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

            // `mapUrl` — не observation, а one-shot чтение (образец `MapModel.refreshAvailability`):
            // колонка правится только синком, а пункт чек-листа всё равно перечитывает файл опросом.
            mapReadinessTask = Task { [weak self] in
                guard let self else { return }
                let race = (try? await self.env.raceStore.getById(raceId)) ?? nil
                guard !Task.isCancelled, self.boundRaceId == raceId else { return }
                self.mapUrl = race?.mapUrl
                self.recomputeMapReadiness()
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

    /// Сводка КП, зачтённых только по фото (ждут проверки судьёй) — нотис «N КП по фото · P баллов».
    /// `nil`, когда ни одного photo-only КП (нотис исчезает целиком). Порт `photoReviewSummary`.
    var photoReview: PhotoReviewSummary? { photoReviewSummary(marks, costOf: costOf) }

    /// Глобальная лента лайтбокса — кадры всех взятий в порядке сетки (тайл несёт КП-чип страницы).
    /// Порт `lightboxPhotos(tiles)`.
    var lightboxPhotos: [LightboxPhoto] { kolco24.lightboxPhotos(tiles) }

    // MARK: - Резолвер путей кадров (шов чтения диска для вьюх)

    /// Абсолютный файловый URL относительного пути кадра (`marks/<markId>/<uuid>.jpg`) — для превью
    /// тайла и `ShareLink` в лайтбоксе. Делегирует инжектированному замыканию графа (прод — над
    /// `PhotoStorage.rootURL`), так что вьюхе не нужен ни GRDB, ни `Photo/`. `nil`, если корня нет
    /// (in-memory окружение).
    func photoURL(_ relPath: String) -> URL? { env.photoURL(relPath) }

    // MARK: - Привязка чипов

    /// Число участников ростера с привязанным чипом (только текущие слоты — устаревшие записи
    /// удалённых участников игнорируются). Делегирует общий Core-хелпер `boundCount(members:bindings:)`.
    func boundCount(members: [TeamMemberItem]) -> Int {
        kolco24.boundCount(members: members, bindings: bindings)
    }

    // MARK: - Чек-лист готовности к старту

    /// Синхронный опрос устройства: геостатус, точность, Low Power Mode и наличие файла подложки.
    /// Зовётся вьюхой из `.task`, `onAppear` (возврат с соседней вкладки не меняет `scenePhase`) и на
    /// `scenePhase == .active` (возврат из Настроек iOS). Все четыре замыкания `env` синхронные и
    /// дешёвые — ни `await`, ни observation здесь не нужны.
    func refreshDeviceState() {
        locationAuth = env.locationAuthorization()
        isReducedAccuracy = env.isReducedAccuracy()
        lowPowerMode = env.isLowPowerMode()
        recomputeMapReadiness()
    }

    /// Пункт карты: нет `mapUrl` → пункта нет вовсе; иначе файл-как-флаг с диска.
    private func recomputeMapReadiness() {
        guard let raceId = boundRaceId, let url = mapUrl, !url.isEmpty else {
            mapReadiness = .notApplicable
            return
        }
        mapReadiness = env.mapFileExists(raceId) ? .ready : .missing
    }

    /// Системный диалог геодоступа. Живёт здесь, а не в `AppModel`: там `env` приватен и обёртки нет,
    /// а `MarksModel` граф и так держит.
    func requestLocationAccess() {
        env.requestLocationAuthorization()
    }

    /// Чек-лист готовности: снимок наблюдений (привязки, КП) + опрошенное состояние устройства +
    /// переданные вьюхой команда/ростер/статус часов. Вся логика статусов — в `readinessItems`.
    func readiness(team: Team?, members: [TeamMemberItem], clock: ClockStatus) -> [ReadinessItem] {
        readinessItems(
            ReadinessInput(
                hasTeam: team != nil,
                teamTitle: team?.teamname ?? "",
                memberCount: members.count,
                boundCount: boundCount(members: members),
                locationAuthorization: locationAuth,
                isReducedAccuracy: isReducedAccuracy,
                checkpointCount: checkpoints.count,
                map: mapReadiness,
                clock: clock,
                lowPowerMode: lowPowerMode
            )
        )
    }
}
