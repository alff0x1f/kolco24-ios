//
//  UploadModel.swift
//  kolco24
//
//  `@Observable @MainActor`-модель экрана «Загрузка данных» (этап 6). Порт ПОВЕДЕНИЯ (не структуры)
//  `ui/upload/UploadScreen.kt` + `UploadStatusModels.kt`: джойнит долговечные per-target счётчики
//  прогресса (`markStore.uploadCounts`) с транзиентными in-memory исходами дренажа
//  (`MarkUploadRepository.outcomeUpdates`) для ВЫБРАННОГО скоупа и отдаёт готовые к рендеру
//  receipt-строки + подзаголовок ряда TeamView.
//
//  Счётчики привязаны к скоупу `(raceId, teamId)`, поэтому `rebind(teamId:raceId:)` перезапускает обе
//  подписки (счётчики + исходы). Stale-guard (конвенция пер-таб моделей этапа 4): между отменой старых
//  задач и первой эмиссией новых состояние синхронно сбрасывается, чтобы данные прежней команды не
//  участвовали в derived.
//
//  Исходы транзиентны (`nil` пока дренаж не отчитался — как `TargetLine.outcome` в Kotlin): «Финиш» (LAN)
//  показывается только когда `outcome != nil || uploaded > 0` (вне финиша LAN обычно недоступен — молчим,
//  чтобы не висела вечная бессмысленная «0/N»).
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

    /// Per-target прогресс скоупа (`total`/`local`/`cloud`); `nil` до первой эмиссии observation.
    private(set) var counts: UploadCounts?
    /// Транзиентные исходы последнего дренажа по целям текущего скоупа; пусто до первого отчёта дренажа.
    private(set) var outcomes: [UploadTarget: TargetUploadOutcome] = [:]

    @ObservationIgnored private let env: AppEnvironment
    /// Инжектированные стенные часы «сейчас» (для относительного времени второй строки) — управляемое
    /// время в тестах; в проде вьюха тикает их раз в ~30 с (порт `produceState`-таймера `UploadScreen`).
    @ObservationIgnored private let nowMs: () -> Int64
    @ObservationIgnored private var countsTask: Task<Void, Never>?
    @ObservationIgnored private var outcomesTask: Task<Void, Never>?
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
        outcomesTask?.cancel()
    }

    // MARK: - Жизненный цикл

    /// Перепривязать подписки счётчиков/исходов к скоупу `(teamId, raceId)` (или снять при `nil`).
    /// Идемпотентно для той же пары. Stale-guard: до первой эмиссии нового скоупа синхронно чистим
    /// `counts`/`outcomes`, чтобы прогресс прежней команды не мигал. Исходы засеиваются текущим снимком
    /// актора (стрим отдаёт лишь ПОСЛЕДУЮЩИЕ изменения — без сида ряд был бы пустым на открытии шита).
    func rebind(teamId: Int?, raceId: Int?) {
        if teamId == boundTeamId, raceId == boundRaceId, countsTask != nil || outcomesTask != nil {
            return
        }
        countsTask?.cancel()
        outcomesTask?.cancel()
        counts = nil
        outcomes = [:]
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
    }

    // MARK: - Действия

    /// Force-flush pull-to-refresh: держит жест до конца дренажа всех pending-скоупов. Порт `onRefresh`
    /// экрана — исходы обновятся сами через `outcomeUpdates`, отдельной кнопки/снекбара нет.
    func refresh() async {
        await env.markUploadRepository.uploadAllPending()
    }

    // MARK: - Derived

    /// Есть ли что показывать (иначе экран рисует empty-state «Пока нечего загружать»). Порт `total > 0`.
    var hasContent: Bool { (counts?.total ?? 0) > 0 }

    /// Подзаголовок ряда «Загрузка данных» в TeamView. Cloud — главная цель (LAN вне гонки всегда 0 и
    /// пугал бы), поэтому pending = `total - cloud`: «N не отправлено» / «Всё отправлено» / «Пока нечего
    /// загружать».
    var pendingLabel: String {
        guard let counts, counts.total > 0 else { return "Пока нечего загружать" }
        let pending = counts.total - counts.cloud
        return pending <= 0 ? "Всё отправлено" : "\(pending) не отправлено"
    }

    /// Receipt-строка «Интернет» (cloud) — показывается всегда (главная цель).
    var cloudLine: ReceiptLine {
        makeLine(label: "Интернет", uploaded: counts?.cloud ?? 0, outcome: outcomes[.cloud], offlineLabel: "нет интернета")
    }

    /// Receipt-строка «Финиш» (LAN) — только когда есть что сказать (`outcome != nil || uploaded > 0`).
    /// Порт `showFinishLine`.
    var finishLine: ReceiptLine? {
        let uploaded = counts?.local ?? 0
        let outcome = outcomes[.local]
        guard outcome != nil || uploaded > 0 else { return nil }
        return makeLine(label: "Финиш", uploaded: uploaded, outcome: outcome, offlineLabel: "сервер недоступен")
    }

    // MARK: - Хелперы

    private var total: Int { counts?.total ?? 0 }

    /// Собрать receipt-строку цели: done/isError-флаги для глифа + вторая строка (когда не done и исход
    /// пришёл). Порт тела `ReceiptLine`.
    private func makeLine(label: String, uploaded: Int, outcome: TargetUploadOutcome?, offlineLabel: String) -> ReceiptLine {
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
