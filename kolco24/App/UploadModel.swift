//
//  UploadModel.swift
//  kolco24
//
//  `@Observable @MainActor`-модель экрана «Загрузка данных» (этап 6, секция «Фото» — этап 7). Порт
//  ПОВЕДЕНИЯ (не структуры) `ui/upload/UploadScreen.kt` + `UploadStatusModels.kt`: джойнит долговечные
//  per-target счётчики прогресса с транзиентными in-memory исходами дренажа
//  (`MarkUploadRepository.outcomeUpdates`) для ВЫБРАННОГО скоупа и отдаёт готовые к рендеру
//  receipt-строки + подзаголовок ряда TeamView.
//
//  Три секции: «Отметки» и «Фото» над ОДНИМ per-target множеством исходов отметок (`outcomes` —
//  зеркало `markUploadOutcomes`): «Отметки» считаются по metadata-only (`uploadCountsMetadata` — доехала
//  ли строка взятия, независимо от кадров), «Фото» — по пофреймовой свёртке (`photoFrameRows` →
//  `foldPhotoFrameCounts`, кадры каждой фото-несущей строки). Секция «Трек» (этап 8) — по счётчикам точек
//  `trackStore.uploadCounts` со СВОИМ потоком исходов (`TrackUploadRepository.outcomeUpdates`), скрыта при
//  нуле точек. Подзаголовок ряда TeamView — по photo-aware `uploadCounts` (кадры учтены) плюс точки трека,
//  чтобы «N не отправлено» покрывало и незалитые кадры, и незалитые точки.
//
//  Счётчики привязаны к скоупу `(raceId, teamId)`, поэтому `rebind(teamId:raceId:)` перезапускает все
//  подписки (три счётчика + исходы). Stale-guard (конвенция пер-таб моделей этапа 4): между отменой старых
//  задач и первой эмиссией новых состояние синхронно сбрасывается, чтобы данные прежней команды не
//  участвовали в derived.
//
//  Экран сгруппирован по целям: карточки «Интернет» и «Финиш (LAN)», в каждой по ряду на скоуп.
//  Исходы транзиентны (`nil` пока дренаж не отчитался — как `TargetLine.outcome` в Kotlin): карточка
//  «Финиш (LAN)» показывается только когда хоть один скоуп отчитался по LAN (`outcome != nil || uploaded > 0`;
//  вне финиша LAN обычно недоступен — молчим, чтобы не висели вечные бессмысленные «0/N»).
//
//  `import SwiftUI`/`GRDB` запрещены (grep-инвариант) — хватает `Observation`; `AsyncValueObservation`
//  счётчиков и `AsyncStream` исходов потребляются без явного упоминания GRDB-типов.
//

import Foundation
import Observation

@MainActor
@Observable
final class UploadModel {

    /// Одна готовая к рендеру receipt-строка цели: лид-глиф (done → зелёный, error/offline → красный,
    /// иначе приглушённая «отправлено, ждём»), лейбл, моноширинный `uploaded/total` и вторая строка
    /// «{относительное время} · {статус}» (только когда не done и исход уже пришёл). Зеркало `ReceiptLine`.
    struct ReceiptLine: Equatable {
        let label: String
        let uploaded: Int
        let total: Int
        /// Всё доехало до этой цели (`uploaded >= total`) — калм-стейт, зелёный `DoneAll`-глиф.
        let done: Bool
        /// Последняя попытка — офлайн/ошибка (красный `CloudOff`-глиф + красная вторая строка).
        let isError: Bool
        /// «{относительное время} · {ok|офлайн-лейбл|ошибка}» — только когда `!done && outcome != nil`.
        let secondLine: String?
    }

    /// Photo-aware per-target прогресс скоупа (`total`/`local`/`cloud`, фото-строка uploaded только когда
    /// И metadata, И кадры доехали); `nil` до первой эмиссии. Питает `pendingLabel`/`hasContent`.
    private(set) var counts: UploadCounts?
    /// Metadata-only прогресс (доехала ли строка взятия, независимо от кадров) — счётчики секции «Отметки».
    private(set) var metadataCounts: UploadCounts?
    /// Пофреймовый прогресс (свёртка `photoFrameRows`) — счётчики секции «Фото». `total == 0` → секция скрыта.
    private(set) var photoCounts: UploadCounts?
    /// Прогресс точек GPS-трека (`track_points`) — счётчики секции «Трек». `total == 0` → секция скрыта.
    private(set) var trackCounts: UploadCounts?
    /// Прогресс судейских пиков (`judge_scans`) гонки — счётчики секции «Судейские отметки». Скоуп —
    /// `raceId` только (судейская станция сканит все команды). `total == 0` → секция скрыта.
    private(set) var judgeCounts: UploadCounts?
    /// Транзиентные исходы последнего дренажа отметок по целям текущего скоупа; пусто до первого отчёта.
    private(set) var outcomes: [UploadTarget: TargetUploadOutcome] = [:]
    /// Транзиентные исходы последнего дренажа трека по целям текущего скоупа; свой поток (`TrackUploadRepository`).
    private(set) var trackOutcomes: [UploadTarget: TargetUploadOutcome] = [:]
    /// Транзиентные исходы последнего дренажа судейских пиков по целям гонки; свой поток
    /// (`JudgeScanUploadRepository`, ключ — `raceId`).
    private(set) var judgeOutcomes: [UploadTarget: TargetUploadOutcome] = [:]

    @ObservationIgnored private let env: AppEnvironment
    /// Инжектированные стенные часы «сейчас» (для относительного времени второй строки) — управляемое
    /// время в тестах. В проде читаются при каждом ре-рендере вьюхи (data-driven обновления счётчиков/
    /// исходов); отдельного тикающего таймера нет — живое «N мин назад» вне спеки этапа 6, поэтому строка
    /// освежается лишь при следующей эмиссии данных.
    @ObservationIgnored private let nowMs: () -> Int64
    @ObservationIgnored private var countsTask: Task<Void, Never>?
    @ObservationIgnored private var metadataTask: Task<Void, Never>?
    @ObservationIgnored private var photoTask: Task<Void, Never>?
    @ObservationIgnored private var trackTask: Task<Void, Never>?
    @ObservationIgnored private var judgeTask: Task<Void, Never>?
    @ObservationIgnored private var outcomesTask: Task<Void, Never>?
    @ObservationIgnored private var trackOutcomesTask: Task<Void, Never>?
    @ObservationIgnored private var judgeOutcomesTask: Task<Void, Never>?
    /// Команда/гонка активных подписок — для идемпотентности `rebind` на той же паре.
    @ObservationIgnored private var boundTeamId: Int?
    @ObservationIgnored private var boundRaceId: Int?

    init(
        env: AppEnvironment,
        nowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.env = env
        self.nowMs = nowMs
    }

    deinit {
        countsTask?.cancel()
        metadataTask?.cancel()
        photoTask?.cancel()
        trackTask?.cancel()
        judgeTask?.cancel()
        outcomesTask?.cancel()
        trackOutcomesTask?.cancel()
        judgeOutcomesTask?.cancel()
    }

    // MARK: - Жизненный цикл

    /// Перепривязать подписки счётчиков/исходов к скоупу `(teamId, raceId)` (или снять при `nil`).
    /// Идемпотентно для той же пары. Stale-guard: до первой эмиссии нового скоупа синхронно чистим
    /// `counts`/`outcomes`, чтобы прогресс прежней команды не мигал. Исходы засеиваются текущим снимком
    /// актора (стрим отдаёт лишь ПОСЛЕДУЮЩИЕ изменения — без сида ряд был бы пустым на открытии шита).
    func rebind(teamId: Int?, raceId: Int?) {
        if teamId == boundTeamId, raceId == boundRaceId,
           countsTask != nil || metadataTask != nil || photoTask != nil
               || trackTask != nil || judgeTask != nil
               || outcomesTask != nil || trackOutcomesTask != nil || judgeOutcomesTask != nil {
            return
        }
        countsTask?.cancel()
        metadataTask?.cancel()
        photoTask?.cancel()
        trackTask?.cancel()
        judgeTask?.cancel()
        outcomesTask?.cancel()
        trackOutcomesTask?.cancel()
        judgeOutcomesTask?.cancel()
        counts = nil
        metadataCounts = nil
        photoCounts = nil
        trackCounts = nil
        judgeCounts = nil
        outcomes = [:]
        trackOutcomes = [:]
        judgeOutcomes = [:]
        boundTeamId = teamId
        boundRaceId = raceId

        guard let teamId, let raceId else { return }
        let scope = TrackScope(raceId: raceId, teamId: teamId)

        let countsObservation = env.markStore.uploadCounts(teamId: teamId, raceId: raceId)
        countsTask = Task { [weak self] in
            do {
                for try await value in countsObservation {
                    guard let self, !Task.isCancelled else { return }
                    self.counts = value
                }
            } catch {}
        }

        let metadataObservation = env.markStore.uploadCountsMetadata(teamId: teamId, raceId: raceId)
        metadataTask = Task { [weak self] in
            do {
                for try await value in metadataObservation {
                    guard let self, !Task.isCancelled else { return }
                    self.metadataCounts = value
                }
            } catch {}
        }

        // «Фото»: `photoFrameRows` (GRDB-`PhotoFrameRow`) → Core-адаптер `asFrameInput` → пофреймовая
        // свёртка `foldPhotoFrameCounts` (Core, без GRDB) — счётчики секции «Фото».
        let photoObservation = env.markStore.photoFrameRows(teamId: teamId, raceId: raceId)
        photoTask = Task { [weak self] in
            do {
                for try await rows in photoObservation {
                    guard let self, !Task.isCancelled else { return }
                    self.photoCounts = foldPhotoFrameCounts(rows.map(\.asFrameInput))
                }
            } catch {}
        }

        let repo = env.markUploadRepository
        let updates = repo.outcomeUpdates
        outcomesTask = Task { [weak self] in
            let seed = await repo.outcomes[scope] ?? [:]
            if let self, !Task.isCancelled { self.outcomes = seed }
            for await snapshot in updates {
                guard let self, !Task.isCancelled else { return }
                self.outcomes = snapshot[scope] ?? [:]
            }
        }

        // «Трек»: счётчики точек (`track_points`) + свой поток исходов из `TrackUploadRepository`.
        let trackObservation = env.trackStore.uploadCounts(teamId: teamId, raceId: raceId)
        trackTask = Task { [weak self] in
            do {
                for try await value in trackObservation {
                    guard let self, !Task.isCancelled else { return }
                    self.trackCounts = value
                }
            } catch {}
        }

        let trackRepo = env.trackUploadRepository
        let trackUpdates = trackRepo.outcomeUpdates
        trackOutcomesTask = Task { [weak self] in
            let seed = await trackRepo.outcomes[scope] ?? [:]
            if let self, !Task.isCancelled { self.trackOutcomes = seed }
            for await snapshot in trackUpdates {
                guard let self, !Task.isCancelled else { return }
                self.trackOutcomes = snapshot[scope] ?? [:]
            }
        }

        // «Судейские отметки»: счётчики пиков гонки (`judge_scans`, скоуп `raceId`) + свой поток исходов
        // из `JudgeScanUploadRepository` (ключ — `raceId`, не `TrackScope`).
        let judgeObservation = env.judgeScanStore.uploadCounts(raceId: raceId)
        judgeTask = Task { [weak self] in
            do {
                for try await value in judgeObservation {
                    guard let self, !Task.isCancelled else { return }
                    self.judgeCounts = value
                }
            } catch {}
        }

        let judgeRepo = env.judgeScanUploadRepository
        let judgeUpdates = judgeRepo.outcomeUpdates
        judgeOutcomesTask = Task { [weak self] in
            let seed = await judgeRepo.outcomes[raceId] ?? [:]
            if let self, !Task.isCancelled { self.judgeOutcomes = seed }
            for await snapshot in judgeUpdates {
                guard let self, !Task.isCancelled else { return }
                self.judgeOutcomes = snapshot[raceId] ?? [:]
            }
        }
    }

    // MARK: - Действия

    /// Force-flush pull-to-refresh: держит жест до конца дренажа всех pending-скоупов. Порт `onRefresh`
    /// экрана — исходы обновятся сами через `outcomeUpdates`, отдельной кнопки/снекбара нет.
    func refresh() async {
        await env.markUploadRepository.uploadAllPending()
        await env.trackUploadRepository.uploadAllPending()
        await env.judgeScanUploadRepository.uploadAllPending()
    }

    // MARK: - Derived

    /// Есть ли что показывать (иначе экран рисует empty-state «Пока нечего загружать»). Порт `total > 0`
    /// по photo-aware `uploadCounts` (любые взятия скоупа) ИЛИ наличию точек трека.
    var hasContent: Bool { (counts?.total ?? 0) > 0 || hasTrack || hasJudge }

    /// Подзаголовок ряда «Загрузка данных» в TeamView. Cloud — главная цель (LAN вне гонки всегда 0 и
    /// пугал бы), поэтому pending = `total - cloud` по всем видам (отметки+кадры+точки): «N не отправлено» /
    /// «Всё отправлено» / «Пока нечего загружать».
    var pendingLabel: String {
        let totalItems = (counts?.total ?? 0) + (trackCounts?.total ?? 0) + (judgeCounts?.total ?? 0)
        guard totalItems > 0 else { return "Пока нечего загружать" }
        let markPending = max(0, (counts?.total ?? 0) - (counts?.cloud ?? 0))
        let trackPending = max(0, (trackCounts?.total ?? 0) - (trackCounts?.cloud ?? 0))
        let judgePending = max(0, (judgeCounts?.total ?? 0) - (judgeCounts?.cloud ?? 0))
        let pending = markPending + trackPending + judgePending
        return pending <= 0 ? "Всё отправлено" : "\(pending) не отправлено"
    }

    // MARK: - Карточки целей («Интернет» / «Финиш (LAN)»)

    /// Скоупы с чем-то записанным (`total > 0`), в порядке рядов: «Отметки» (metadata-only), «Фото»
    /// (пофреймово), «GPS-трек», «Судейские отметки». Нулевой скоуп скрыт — иначе, например, трек-only
    /// скоуп рисовал бы вводящий в заблуждение ряд «0/0» отметок.
    private var scopes: [ScopeProgress] {
        let all = [
            ScopeProgress(title: "Отметки", counts: metadataCounts,
                          cloudOutcome: outcomes[.cloud], localOutcome: outcomes[.local]),
            ScopeProgress(title: "Фото", counts: photoCounts,
                          cloudOutcome: outcomes[.cloud], localOutcome: outcomes[.local]),
            ScopeProgress(title: "GPS-трек", counts: trackCounts,
                          cloudOutcome: trackOutcomes[.cloud], localOutcome: trackOutcomes[.local]),
            ScopeProgress(title: "Судейские отметки", counts: judgeCounts,
                          cloudOutcome: judgeOutcomes[.cloud], localOutcome: judgeOutcomes[.local]),
        ]
        return all.filter { $0.total > 0 }
    }

    var hasMarks: Bool { (metadataCounts?.total ?? 0) > 0 }
    var hasPhotos: Bool { (photoCounts?.total ?? 0) > 0 }
    var hasTrack: Bool { (trackCounts?.total ?? 0) > 0 }
    var hasJudge: Bool { (judgeCounts?.total ?? 0) > 0 }

    /// Карточка «Интернет» (cloud): по ряду на каждый записанный скоуп — показывается всегда.
    var internetLines: [ReceiptLine] {
        scopes.map {
            makeLine(label: $0.title, uploaded: $0.cloud, total: $0.total,
                     outcome: $0.cloudOutcome, offlineLabel: "нет интернета")
        }
    }

    /// Карточка «Финиш (LAN)»: пусто, пока LAN не отчитался ни по одному скоупу
    /// (`outcome != nil || uploaded > 0`) — вне финиша это обычное состояние, и экран читается одной
    /// карточкой. Когда показана, перечисляет ВСЕ скоупы: «0/N» рядом с отчитавшимся соседом осмысленно
    /// (сервер финиша доступен, а этот скоуп туда ещё не доехал). Порт `showFinishSection`.
    var finishLines: [ReceiptLine] {
        let scopes = scopes
        guard scopes.contains(where: { $0.localOutcome != nil || $0.local > 0 }) else { return [] }
        return scopes.map {
            makeLine(label: $0.title, uploaded: $0.local, total: $0.total,
                     outcome: $0.localOutcome, offlineLabel: "сервер недоступен")
        }
    }

    // MARK: - Хелперы

    private struct ScopeProgress {
        let title: String
        let counts: UploadCounts?
        let cloudOutcome: TargetUploadOutcome?
        let localOutcome: TargetUploadOutcome?

        var total: Int { counts?.total ?? 0 }
        var cloud: Int { counts?.cloud ?? 0 }
        var local: Int { counts?.local ?? 0 }
    }

    /// Собрать receipt-строку цели: done/isError-флаги для глифа + вторая строка (когда не done и исход
    /// пришёл). Порт тела `ReceiptLine`.
    private func makeLine(label: String, uploaded: Int, total: Int, outcome: TargetUploadOutcome?, offlineLabel: String) -> ReceiptLine {
        let done = uploaded >= total
        let isError = outcome?.kind == .error || outcome?.kind == .offline
        var secondLine: String?
        if !done, let outcome {
            secondLine = "\(relativeTimeRu(atWallMs: outcome.atWallMs, nowMs: nowMs())) · \(outcomeLabel(outcome.kind, offlineLabel: offlineLabel))"
        }
        return ReceiptLine(label: label, uploaded: uploaded, total: total, done: done, isError: isError, secondLine: secondLine)
    }

    /// Короткий лейбл исхода pending-цели: «ok» / офлайн-лейбл цели / «ошибка». Порт `outcomeLabelRu`.
    private func outcomeLabel(_ kind: UploadResultKind, offlineLabel: String) -> String {
        switch kind {
        case .ok: return "ok"
        case .offline: return offlineLabel
        case .error: return "ошибка"
        }
    }
}
