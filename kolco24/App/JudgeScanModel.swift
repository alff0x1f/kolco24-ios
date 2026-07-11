//
//  JudgeScanModel.swift
//  kolco24
//
//  `@Observable @MainActor`-хост-редьюсер судейского экрана «Отметка старта/финиша» (этап 10). Порт
//  ПОВЕДЕНИЯ (не структуры) `ui/admin/JudgeScanModel.kt` + `JudgeScanScreen.kt`: одна длинная NFC-сессия
//  на открытый экран (batch-скан, как на Android) → каждый распознанный по пулу `member_tags` браслет
//  пишется write-once строкой в `judge_scans` и идемпотентно дренится на обе цели.
//
//  Пул `member_tags` наблюдается (`observeForRace`); сканы игнорируются до ПЕРВОЙ эмиссии пула
//  (null-sentinel `pool == nil`). Гейт «пул синхронизирован, но пуст» ≠ «не синхронизирован» —
//  тот же, что в bind-флоу этапа 5 (`hasBeenSynced` → иначе инлайн-`refreshMemberTags`): пустой
//  несинхронизированный пул при скане поднимает `poolNotReady` (плейт «Синхронизируйте гонку») и
//  запускает фоновый refresh.
//
//  Обработка одного чтения сериализована единым `for await` по стриму сканера (замена Android-`scanMutex`).
//  Записи в БД — в НЕструктурированном `Task`, захватывающем СТОР и РЕПОЗИТОРИЙ (не `self`): уход с
//  экрана не обрывает начатый `insert`/`uploadPending` (§6). Плюс выделенный 60-секундный drain-цикл,
//  пока экран открыт (аналог Android-цикла, привязанный к жизни экрана), + финальный flush в `stop()`.
//
//  `import SwiftUI`/`GRDB`/`CoreNFC` запрещены (grep-инвариант) — хватает `Observation`/`Foundation`;
//  модель зависит только от протоколов `Core/` + сторов/репозиториев. Прод-сканер `NfcChipScanner`
//  инстанцируется фабрикой `AppModel.makeJudgeScanModel` (App-слой в одном модуле — CoreNFC не нужен);
//  тесты подают `FakeChipScanner` в `start(scanner:)`.
//

import Foundation
import Observation

@MainActor
@Observable
final class JudgeScanModel: Identifiable {

    /// Стабильный id (для `.fullScreenCover`/навигации, если понадобится).
    nonisolated let id = UUID()

    /// Одна запись ленты недавних сканов: результат классификации + метка стенных часов (для строки
    /// «HH:mm»). `seq` — монотонный идентификатор для `Identifiable`/анимации списка.
    struct FeedItem: Equatable, Identifiable {
        let seq: Int
        let result: JudgeScanResult
        let atWallMs: Int64
        var id: Int { seq }
    }

    /// «start»/«finish» — тип судейского события (админ-подстраница). Пишется в `judge_scans.eventType`.
    let eventType: String

    // MARK: - UI-состояние (observable)

    /// Лента недавних сканов (новые сверху), капится `feedCap`. Только чипы (recorded/kpChip/unknownChip);
    /// `poolNotReady` в ленту не идёт (это статус синхронизации, а не событие чипа).
    private(set) var feed: [FeedItem] = []
    /// Последний результат скана — драйвит крупный статус-баннер экрана.
    private(set) var lastResult: JudgeScanResult?
    /// Нужно ли показать плейт «Синхронизируйте гонку»: `true`, когда пул пуст и синхронизации не было
    /// (скан отклонён как `poolNotReady`). Сбрасывается на успешном скане / непустом пуле.
    private(set) var needsSync = false
    /// Загрузился ли пул хотя бы раз (первая эмиссия observation). До этого сканы игнорируются
    /// (null-sentinel). Экран может показать «загрузка пула»; тесты ждут этого перед эмиссией чипа.
    private(set) var poolLoaded = false

    /// Максимум записей в ленте недавних сканов (порт `RECENT_LIMIT`).
    static let feedCap = 20
    /// Интервал выделенного drain-цикла судейских строк, пока экран открыт (порт Android-цикла).
    static let defaultDrainIntervalMs: Int = 60_000

    /// Потокобезопасное зеркало «экран жив» для `NfcChipScanner.shouldRestart` (читается на делегатной
    /// NFC-очереди, пишется здесь на MainActor). `true` с момента `start`, `false` на `stop`.
    @ObservationIgnored let liveness = ScanLiveness(alive: true)

    // MARK: - Пул member_tags (не-observable, null-sentinel)

    /// Пул браслетов гонки; `nil` до первой эмиссии observation — сканы до неё игнорируются (порт
    /// «ignore scans until first pool emission»). После первой эмиссии — актуальный снимок.
    @ObservationIgnored private var pool: [MemberTag]?
    /// Кэш «пул этой гонки уже подтверждён синхронизированным» (порт `hasSyncedPool`) — повторные сканы
    /// над пустым пулом не дёргают refresh заново.
    @ObservationIgnored private var hasSyncedPool = false
    /// Монотонный счётчик id ленты.
    @ObservationIgnored private var feedSeq = 0

    // MARK: - Зависимости (граф — через AppModel.makeJudgeScanModel)

    @ObservationIgnored let raceId: Int
    @ObservationIgnored private let judgeScanStore: JudgeScanStore
    @ObservationIgnored private let repository: JudgeScanUploadRepository
    @ObservationIgnored private let memberTagsRepository: MemberTagsRepository
    @ObservationIgnored private let feedback: any ScanFeedbackPlaying
    @ObservationIgnored private let installId: String
    /// Генератор id судейской строки (UUID в проде; детерминированный в тестах).
    @ObservationIgnored private let newScanId: () -> String
    /// Интервал drain-цикла (инжектится, чтобы тесты не ждали реальные 60 с).
    @ObservationIgnored private let drainIntervalMs: Int

    // MARK: - Задачи

    @ObservationIgnored private var scanner: (any ChipScanning)?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var poolTask: Task<Void, Never>?
    @ObservationIgnored private var drainLoopTask: Task<Void, Never>?

    init(
        raceId: Int,
        eventType: String,
        judgeScanStore: JudgeScanStore,
        repository: JudgeScanUploadRepository,
        memberTagsRepository: MemberTagsRepository,
        feedback: any ScanFeedbackPlaying,
        installId: String,
        newScanId: @escaping () -> String = { UUID().uuidString },
        drainIntervalMs: Int = JudgeScanModel.defaultDrainIntervalMs
    ) {
        self.raceId = raceId
        self.eventType = eventType
        self.judgeScanStore = judgeScanStore
        self.repository = repository
        self.memberTagsRepository = memberTagsRepository
        self.feedback = feedback
        self.installId = installId
        self.newScanId = newScanId
        self.drainIntervalMs = drainIntervalMs
        startPoolObservation()
    }

    deinit {
        // Синхронная часть teardown для deinit-only-пути: гасим liveness, отменяем задачи и останавливаем
        // сканер. Финальный flush в deinit НЕ шлём (нет доступа к async на nonisolated deinit — его делает
        // явный `stop()`); запись строк уже живёт в собственных Task (§6).
        liveness.set(false)
        streamTask?.cancel()
        poolTask?.cancel()
        drainLoopTask?.cancel()
        scanner?.stop()
    }

    // MARK: - Жизненный цикл

    /// Тестовый вход: стартует сканирование по инжектированному [scanner] (`FakeChipScanner`).
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
        startDrainLoop()
    }

    /// Привязать прод-сканер (`AppModel.makeJudgeScanModel`); вьюха стартует его `beginScanning()`.
    func attachProductionScanner(_ scanner: any ChipScanning) {
        self.scanner = scanner
    }

    /// Старт привязанного прод-сканера (вьюха, `.task`). No-op без сканера (тесты стартуют `start(scanner:)`).
    func beginScanning() {
        guard let scanner else { return }
        start(scanner: scanner)
    }

    /// Закрытие экрана: гасит liveness, отменяет стрим + drain-цикл, шлёт ФИНАЛЬНЫЙ flush (fire-and-forget,
    /// захватывает РЕПОЗИТОРИЙ — переживает уход с экрана, §6) и останавливает сканер. Записи строк
    /// (`insert`) уже в своих Task и не обрываются.
    func stop() {
        liveness.set(false)
        streamTask?.cancel()
        streamTask = nil
        drainLoopTask?.cancel()
        drainLoopTask = nil
        let repo = repository
        let rid = raceId
        Task { await repo.uploadPending(raceId: rid) }
        scanner?.stop()
    }

    // MARK: - Наблюдение пула

    private func startPoolObservation() {
        let observation = memberTagsRepository.observeForRace(raceId)
        poolTask = Task { [weak self] in
            do {
                for try await tags in observation {
                    guard let self, !Task.isCancelled else { return }
                    self.pool = tags
                    self.poolLoaded = true
                    // Непустой пул — заведомо синхронизирован; снимаем плейт «Синхронизируйте гонку».
                    if !tags.isEmpty {
                        self.hasSyncedPool = true
                        self.needsSync = false
                    }
                }
            } catch {}
        }
    }

    // MARK: - Выделенный 60-с drain-цикл (пока экран открыт)

    private func startDrainLoop() {
        drainLoopTask?.cancel()
        let repo = repository
        let rid = raceId
        let intervalMs = drainIntervalMs
        drainLoopTask = Task {
            while !Task.isCancelled {
                await repo.uploadPending(raceId: rid)
                do {
                    try await Task.sleep(for: .milliseconds(intervalMs))
                } catch {
                    return // отменён (уход с экрана)
                }
            }
        }
    }

    // MARK: - Обработка одного чтения (порт onScanTag)

    /// Один прочитанный чип → пул/`hasBeenSynced`/инлайн-refresh → `classifyJudgeScan` → запись строки
    /// (только `recorded`) + фидбек + лента. Сериализовано единым `for await` (замена `scanMutex`).
    func processReading(_ reading: TagReading) async {
        // null-sentinel: до первой эмиссии пула сканы игнорируем (пул неизвестен).
        guard var pool = self.pool else { return }
        let poolReady = await resolvePoolReady(pool: &pool)
        let uid = reading.uid  // нормализован сканером (`normalizeNfcUid`)
        let memberNumber = pool.first { $0.nfcUid == uid }?.number
        let result = classifyJudgeScan(
            uid: uid, memberNumber: memberNumber, hasKpCode: reading.code != nil, poolReady: poolReady
        )
        apply(result, sample: reading.sample)
    }

    /// Разрешает `poolReady` для `classifyJudgeScan`, попутно двигая гейт синхронизации (порт
    /// bind-флоу этапа 5). Непустой пул → готов; пустой, но подтверждён/синхронизирован → готов; пустой
    /// несинхронизированный → инлайн-`refreshMemberTags` (успех → готов + перечитать пул; офлайн/ошибка →
    /// не готов). Мутирует переданный [pool] на перечитанный снимок при успешном refresh.
    private func resolvePoolReady(pool: inout [MemberTag]) async -> Bool {
        if !pool.isEmpty { return true }
        if hasSyncedPool { return true }
        // Пустой пул и в этом сеансе ещё не подтверждён: сперва долговечная запись `sync_meta`.
        if (try? await memberTagsRepository.hasBeenSynced(raceId: raceId)) == true {
            hasSyncedPool = true
            return true
        }
        // Синка ещё не было — инлайн-refresh. Успех → готов + перечитать пул; офлайн/ошибка → не готов.
        let result = try? await memberTagsRepository.refreshMemberTags(raceId)
        switch result {
        case .updated, .notModified, .skipped:
            hasSyncedPool = true
            pool = await currentPool()
            return true
        case .offline, .forbidden, .httpError, .none:
            return false
        }
    }

    /// Свёртка результата в UI + фидбек + (для `recorded`) запись строки. `recorded` → success + строка;
    /// `kpChip`/`unknownChip` → failure; `poolNotReady` → плейт синхронизации + neutral (в ленту не идёт).
    private func apply(_ result: JudgeScanResult, sample: TimeSample) {
        lastResult = result
        switch result {
        case .poolNotReady:
            needsSync = true
            feedback.play(.neutral)
            return  // статус синхронизации — не событие чипа, в ленту не пишем
        case let .recorded(uid, number):
            needsSync = false
            recordScan(uid: uid, number: number, sample: sample)
            feedback.play(.success)
        case .kpChip, .unknownChip:
            feedback.play(.failure)
        }
        pushFeed(result, atWallMs: sample.wallMs)
    }

    /// Собрать write-once строку + персист/дренаж в НЕструктурированном Task, захватывающем СТОР и
    /// РЕПОЗИТОРИЙ (не `self`) — уход с экрана не обрывает `insert`/`uploadPending` (§6). После записи
    /// сразу пробуем дослать (fire-and-forget: сервер ещё не задеплоен — self-heal позже).
    private func recordScan(uid: String, number: Int, sample: TimeSample) {
        let scan = makeJudgeScan(
            id: newScanId(), raceId: raceId, eventType: eventType,
            participantNumber: number, nfcUid: uid, sample: sample, sourceInstallId: installId
        )
        let store = judgeScanStore
        let repo = repository
        let rid = raceId
        Task {
            try? await store.insert(scan)
            await repo.uploadPending(raceId: rid)
        }
    }

    private func pushFeed(_ result: JudgeScanResult, atWallMs: Int64) {
        feedSeq += 1
        feed.insert(FeedItem(seq: feedSeq, result: result, atWallMs: atWallMs), at: 0)
        if feed.count > Self.feedCap {
            feed.removeLast(feed.count - Self.feedCap)
        }
    }

    /// Первое значение пула member-тегов гонки (аналог Kotlin `.first()`).
    private func currentPool() async -> [MemberTag] {
        do {
            for try await tags in memberTagsRepository.observeForRace(raceId) {
                return tags
            }
        } catch {}
        return []
    }
}
