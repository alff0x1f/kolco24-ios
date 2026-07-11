//
//  MemberChipCheckModel.swift
//  kolco24
//
//  `@Observable @MainActor`-хост read-only проверки браслетов участников «Проверка браслетов» (этап 10).
//  Порт ПОВЕДЕНИЯ (не структуры) `ui/admin/MemberChipCheckModel.kt` + `CheckMemberChipScreen.kt`: одна
//  длинная NFC-сессия на экран → каждый чип идентифицируется полностью оффлайн по UID против пула
//  `member_tags`. Ничего не пишется (transient) — только UI-лента.
//
//  Пул наблюдается (`observeForRace`); сканы игнорируются до ПЕРВОЙ эмиссии (null-sentinel `pool == nil`).
//  Матч UID-only (браслет не несёт K24-кода); прочитанный код — лишь диагностика, чтобы отличить
//  ошибочно тапнутый чип КП (`kpChip`) от по-настоящему неизвестного браслета (`unknown`). Размер пула
//  идёт в idle-строку: `0` — признак «пул не синхронизирован».
//
//  `import SwiftUI`/`GRDB`/`CoreNFC` запрещены (grep-инвариант) — хватает `Observation`/`Foundation`.
//  Прод-сканер `NfcChipScanner` инстанцируется фабрикой `AppModel.makeMemberChipCheckModel`; тесты
//  подают `FakeChipScanner` в `start(scanner:)`.
//

import Foundation
import Observation

@MainActor
@Observable
final class MemberChipCheckModel: Identifiable {

    /// Стабильный id (навигация/`Identifiable`).
    nonisolated let id = UUID()

    /// Одна запись ленты недавних проверок: результат + метка стенных часов. `seq` — монотонный id.
    struct FeedItem: Equatable, Identifiable {
        let seq: Int
        let result: MemberChipCheckResult
        let atWallMs: Int64
        var id: Int { seq }
    }

    // MARK: - UI-состояние (observable)

    /// Лента недавних проверок (новые сверху), капится `feedCap`.
    private(set) var feed: [FeedItem] = []
    /// Последний результат — драйвит крупный статус-hero экрана.
    private(set) var lastResult: MemberChipCheckResult?
    /// Размер синхронизированного пула браслетов (idle-строка; `0` — признак «не синхронизирован»).
    private(set) var poolSize = 0
    /// Загрузился ли пул (первая эмиссия observation). До этого сканы игнорируются (null-sentinel).
    private(set) var loaded = false

    /// Максимум записей в ленте.
    static let feedCap = 20

    /// Потокобезопасное зеркало «экран жив» для `NfcChipScanner.shouldRestart`.
    @ObservationIgnored let liveness = ScanLiveness(alive: true)

    // MARK: - Пул (не-observable, null-sentinel)

    /// Пул браслетов гонки; `nil` до первой эмиссии observation — сканы до неё игнорируются.
    @ObservationIgnored private var pool: [MemberTag]?
    /// Монотонный счётчик id ленты.
    @ObservationIgnored private var feedSeq = 0

    // MARK: - Зависимости

    @ObservationIgnored let raceId: Int
    @ObservationIgnored private let memberTagStore: MemberTagStore
    @ObservationIgnored private let feedback: any ScanFeedbackPlaying

    // MARK: - Задачи

    @ObservationIgnored private var scanner: (any ChipScanning)?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var poolTask: Task<Void, Never>?

    init(
        raceId: Int,
        memberTagStore: MemberTagStore,
        feedback: any ScanFeedbackPlaying
    ) {
        self.raceId = raceId
        self.memberTagStore = memberTagStore
        self.feedback = feedback
        startPoolObservation()
    }

    deinit {
        liveness.set(false)
        streamTask?.cancel()
        poolTask?.cancel()
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

    /// Привязать прод-сканер (`AppModel.makeMemberChipCheckModel`); вьюха стартует `beginScanning()`.
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

    // MARK: - Наблюдение пула

    private func startPoolObservation() {
        let observation = memberTagStore.observeForRace(raceId)
        poolTask = Task { [weak self] in
            do {
                for try await tags in observation {
                    guard let self, !Task.isCancelled else { return }
                    self.pool = tags
                    self.poolSize = tags.count
                    self.loaded = true
                }
            } catch {}
        }
    }

    // MARK: - Обработка одного чтения

    /// Один прочитанный чип → матч UID против пула → `classifyMemberChipCheck` → фидбек + лента.
    func processReading(_ reading: TagReading) async {
        // null-sentinel: до первой эмиссии пула сканы игнорируем.
        guard let pool = self.pool else { return }
        let uid = reading.uid
        let memberNumber = pool.first { $0.nfcUid == uid }?.number
        let result = classifyMemberChipCheck(
            uid: uid, memberNumber: memberNumber, hasKpCode: reading.code != nil
        )
        apply(result, sample: reading.sample)
    }

    /// Свёртка результата в UI + фидбек. `ok` → success; `kpChip`/`unknown` → failure.
    private func apply(_ result: MemberChipCheckResult, sample: TimeSample) {
        lastResult = result
        switch result {
        case .ok:
            feedback.play(.success)
        case .kpChip, .unknown:
            feedback.play(.failure)
        }
        pushFeed(result, atWallMs: sample.wallMs)
    }

    private func pushFeed(_ result: MemberChipCheckResult, atWallMs: Int64) {
        feedSeq += 1
        feed.insert(FeedItem(seq: feedSeq, result: result, atWallMs: atWallMs), at: 0)
        if feed.count > Self.feedCap {
            feed.removeLast(feed.count - Self.feedCap)
        }
    }
}
