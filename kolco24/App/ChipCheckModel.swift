//
//  ChipCheckModel.swift
//  kolco24
//
//  `@Observable @MainActor`-хост read-only проверки КП-чипов «Проверка чипов КП» (этап 10). Порт
//  ПОВЕДЕНИЯ (не структуры) `ui/admin/ChipCheckModel.kt` + `CheckChipScreen.kt`: одна длинная NFC-сессия
//  на открытый экран (batch-скан) → каждый чип идентифицируется полностью оффлайн против
//  синхронизированной легенды. Ничего не пишется в БД и на сервер (transient) — только UI-лента.
//
//  Легенда наблюдается двумя подписками (`observeTagsForRace`/`observeCheckpointsForRace`); сканы
//  игнорируются до ПЕРВОЙ эмиссии тегов (null-sentinel `tags == nil`). `bid` чипа — `LegendCrypto.bid`
//  над прочитанным K24-кодом; матч тега по `bid`, КП по `tag.checkpointId`, «чипов на КП» —
//  число тегов с тем же `checkpointId`. Диагностика: `changedNibbles` подсвечивает изменившиеся
//  относительно предыдущего скана nibbles UID.
//
//  Обработка одного чтения сериализована единым `for await` по стриму сканера. Записей в БД нет —
//  §6 не нужен; закрытие экрана лишь останавливает сканер и отменяет задачи.
//
//  `import SwiftUI`/`GRDB`/`CoreNFC` запрещены (grep-инвариант) — хватает `Observation`/`Foundation`;
//  модель зависит только от протоколов `Core/` + сторов. Прод-сканер `NfcChipScanner` инстанцируется
//  фабрикой `AppModel.makeChipCheckModel`; тесты подают `FakeChipScanner` в `start(scanner:)`.
//

import Foundation
import Observation

@MainActor
@Observable
final class ChipCheckModel: Identifiable {

    /// Стабильный id (навигация/`Identifiable`).
    nonisolated let id = UUID()

    /// Одна запись ленты недавних проверок: результат + метка стенных часов. `seq` — монотонный id.
    struct FeedItem: Equatable, Identifiable {
        let seq: Int
        let result: ChipCheckResult
        let atWallMs: Int64
        var id: Int { seq }
    }

    // MARK: - UI-состояние (observable)

    /// Лента недавних проверок (новые сверху), капится `feedCap`.
    private(set) var feed: [FeedItem] = []
    /// Последний результат — драйвит крупный статус-hero экрана.
    private(set) var lastResult: ChipCheckResult?
    /// Позиции изменившихся nibbles UID последнего скана (относительно предыдущего) — для diff-подсветки.
    private(set) var changed: Set<Int> = []
    /// Загрузилась ли легенда (первая эмиссия тегов). До этого сканы игнорируются (null-sentinel).
    private(set) var loaded = false

    /// Максимум записей в ленте.
    static let feedCap = 20

    /// Потокобезопасное зеркало «экран жив» для `NfcChipScanner.shouldRestart`.
    @ObservationIgnored let liveness = ScanLiveness(alive: true)

    // MARK: - Легенда (не-observable, null-sentinel по тегам)

    /// Теги гонки; `nil` до первой эмиссии observation — сканы до неё игнорируются.
    @ObservationIgnored private var tags: [Tag]?
    /// КП гонки по id (для резолва тега → КП).
    @ObservationIgnored private var checkpointsById: [Int: Checkpoint] = [:]
    /// UID предыдущего скана — база для `changedNibbles`.
    @ObservationIgnored private var previousUid: String?
    /// Монотонный счётчик id ленты.
    @ObservationIgnored private var feedSeq = 0

    // MARK: - Зависимости

    @ObservationIgnored let raceId: Int
    @ObservationIgnored private let tagStore: TagStore
    @ObservationIgnored private let checkpointStore: CheckpointStore
    @ObservationIgnored private let feedback: any ScanFeedbackPlaying

    // MARK: - Задачи

    @ObservationIgnored private var scanner: (any ChipScanning)?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var tagsTask: Task<Void, Never>?
    @ObservationIgnored private var cpTask: Task<Void, Never>?

    init(
        raceId: Int,
        tagStore: TagStore,
        checkpointStore: CheckpointStore,
        feedback: any ScanFeedbackPlaying
    ) {
        self.raceId = raceId
        self.tagStore = tagStore
        self.checkpointStore = checkpointStore
        self.feedback = feedback
        startLegendObservation()
    }

    deinit {
        liveness.set(false)
        streamTask?.cancel()
        tagsTask?.cancel()
        cpTask?.cancel()
        scanner?.stop()
    }

    // MARK: - Жизненный цикл

    /// Тестовый вход: стартует сканирование по инжектированному [scanner].
    func start(scanner: any ChipScanning) {
        self.scanner = scanner
        liveness.set(true)
        let readings = scanner.readings()
        scanner.start()
        streamTask = Task { [weak self] in
            for await reading in readings {
                guard let self else { return }
                await self.processReading(reading)
            }
        }
    }

    /// Привязать прод-сканер (`AppModel.makeChipCheckModel`); вьюха стартует его `beginScanning()`.
    func attachProductionScanner(_ scanner: any ChipScanning) {
        self.scanner = scanner
    }

    /// Старт привязанного прод-сканера (вьюха, `.task`). No-op без сканера.
    func beginScanning() {
        guard let scanner else { return }
        start(scanner: scanner)
    }

    /// Закрытие экрана: гасит liveness, отменяет стрим и останавливает сканер. Записей в БД нет.
    func stop() {
        liveness.set(false)
        streamTask?.cancel()
        streamTask = nil
        scanner?.stop()
    }

    // MARK: - Наблюдение легенды

    private func startLegendObservation() {
        let tagsObs = tagStore.observeTagsForRace(raceId)
        tagsTask = Task { [weak self] in
            do {
                for try await rows in tagsObs {
                    guard let self, !Task.isCancelled else { return }
                    self.tags = rows
                    self.loaded = true
                }
            } catch {}
        }
        let cpObs = checkpointStore.observeCheckpointsForRace(raceId)
        cpTask = Task { [weak self] in
            do {
                for try await rows in cpObs {
                    guard let self, !Task.isCancelled else { return }
                    self.checkpointsById = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                }
            } catch {}
        }
    }

    // MARK: - Обработка одного чтения

    /// Один прочитанный чип → `bid`/тег/КП/«чипов на КП» → `classifyChipCheck` → фидбек + лента.
    func processReading(_ reading: TagReading) async {
        // null-sentinel: до первой эмиссии тегов сканы игнорируем (легенда неизвестна).
        guard let tags = self.tags else { return }
        let uid = reading.uid
        let bid = reading.code.map { LegendCrypto.bid(code: $0) }
        let tag = bid.flatMap { b in tags.first { $0.bid == b } }
        let checkpoint = tag.flatMap { checkpointsById[$0.checkpointId] }
        let chipsOnKp = tag.map { t in tags.filter { $0.checkpointId == t.checkpointId }.count } ?? 0
        let result = classifyChipCheck(
            uid: uid, bid: bid, tag: tag, checkpoint: checkpoint, chipsOnKp: chipsOnKp
        )
        apply(result, sample: reading.sample)
    }

    /// Свёртка результата в UI + фидбек. `ok` → success; прочее → failure. Diff-подсветка от предыдущего UID.
    private func apply(_ result: ChipCheckResult, sample: TimeSample) {
        changed = changedNibbles(uid: result.uid, previous: previousUid)
        previousUid = result.uid
        lastResult = result
        switch result {
        case .ok:
            feedback.play(.success)
        case .unknownChip, .inconsistent, .noCode:
            feedback.play(.failure)
        }
        pushFeed(result, atWallMs: sample.wallMs)
    }

    private func pushFeed(_ result: ChipCheckResult, atWallMs: Int64) {
        feedSeq += 1
        feed.insert(FeedItem(seq: feedSeq, result: result, atWallMs: atWallMs), at: 0)
        if feed.count > Self.feedCap {
            feed.removeLast(feed.count - Self.feedCap)
        }
    }
}
