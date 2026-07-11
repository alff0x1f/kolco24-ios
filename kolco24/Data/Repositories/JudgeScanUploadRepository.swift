//
//  JudgeScanUploadRepository.swift
//  kolco24
//
//  Порт дренажа выгрузки судейских пиков из `data/JudgeScanRepository.kt` (upload-часть) —
//  **структурный клон** `TrackUploadRepository` (этап 8) с двумя отличиями: ключ исходов — `raceId`
//  (`Int`), не `TrackScope` (судейская станция сканит все команды гонки, скоуп — только гонка), и
//  тело POST несёт `source_install_id`, но **без** `team_id`. Строки **write-once** — маркировка
//  простым `markUploadedLocal/Cloud(ids:)` без version-guard (нет аналога `addMember`/`attachLocation`).
//
//  Как и track/marks: Kotlin-`Mutex.tryLock()` заменён изоляцией `actor` + флагом `inFlight`; исходы
//  дренажа отдаются через `AsyncStream` (идиома `TrustedClock.statusUpdates`). Каждая гонка дренится
//  в обе цели независимо — сначала Local («Финиш», LAN), потом Cloud («Интернет», HTTPS); каждая цель
//  — generic-циклом `drainUploadLoop` (из `MarkUploadRepository.swift`).
//
//  Файл под `Data/`; переиспользует `drainUploadLoop`/`uploadResultKind` (`MarkUpload…`) и
//  `JudgeScanStore` (этап 2). Никакой GRDB-тип не пересекает границу (`Row` в `drainUploadLoop` —
//  generic-параметр), поэтому `import GRDB` не нужен.
//

import Foundation
import os

/// Логгер дренажа выгрузки судейских пиков (ошибки БД внутри цикла сворачиваются в `.error` + лог,
/// движок не роняет процесс — конвенция этапа 2 «decode error → fallback + log»).
private let judgeScanUploadLog = Logger(subsystem: "kolco24", category: "JudgeScanUpload")

/// Идемпотентная батч-выгрузка судейских пиков в обе цели (LAN «Финиш» + облако «Интернет») с
/// независимыми флагами `uploadedLocal`/`uploadedCloud`, self-heal при офлайне/ошибках. `actor`:
/// изоляция + флаг `inFlight` заменяют Kotlin `Mutex.tryLock()` — перекрывающиеся триггеры молча
/// пропускают (проигравший — no-op, следующий триггер догонит). Исходы дренажа копятся в `outcomes`
/// (ключ — `raceId`) и стримятся через `outcomeUpdates` (идиома `TrustedClock.statusUpdates`).
actor JudgeScanUploadRepository {
    /// Максимум пиков на один запрос (совпадает с `LIMIT` в `unuploaded*`-запросах).
    static let uploadBatch = 500

    private let judgeScanStore: JudgeScanStore
    /// Облачный клиент (HTTPS) — цель `.cloud`.
    private let cloud: ApiClient
    /// LAN-клиент (таймаут 3 с) — цель `.local`; вне сети быстро фейлится в `.offline`.
    private let local: ApiClient
    /// `source_install_id` тела запроса (провенанс устройства, тот же UUID, что заголовок `X-Install-Id`).
    private let installId: String
    /// Метка стенных часов исхода (для строки «N мин назад»); инжектится ради управляемого времени в тестах.
    private let wallNow: () -> Int64

    /// tryLock-аналог: пока один проход идёт, перекрывающийся триггер выходит no-op'ом.
    private var inFlight = false

    /// Последний исход дренажа по каждой цели каждой гонки. Читается моделью экрана (`await`).
    private(set) var outcomes: [Int: [UploadTarget: TargetUploadOutcome]] = [:]

    /// Поток снимков `outcomes` (полный словарь на каждое изменение; равные снимки дедупятся вручную).
    /// Потребитель — `UploadModel` (этап 10, задача 8). Идиома `TrustedClock.statusUpdates`.
    nonisolated let outcomeUpdates: AsyncStream<[Int: [UploadTarget: TargetUploadOutcome]]>
    private let continuation: AsyncStream<[Int: [UploadTarget: TargetUploadOutcome]]>.Continuation
    /// Последний опубликованный снимок — для ручного дедупа равных значений.
    private var lastPublished: [Int: [UploadTarget: TargetUploadOutcome]] = [:]

    init(
        judgeScanStore: JudgeScanStore,
        cloud: ApiClient,
        local: ApiClient,
        installId: String,
        wallNow: @escaping () -> Int64
    ) {
        self.judgeScanStore = judgeScanStore
        self.cloud = cloud
        self.local = local
        self.installId = installId
        self.wallNow = wallNow

        var cont: AsyncStream<[Int: [UploadTarget: TargetUploadOutcome]]>.Continuation!
        self.outcomeUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        self.continuation = cont
    }

    // MARK: - Входы (tryLock-guard)

    /// Слить все pending-пики одной гонки в обе цели. Guard'ится, чтобы два прохода не задвоили
    /// отправку; проигравший — no-op (следующий триггер догонит). Порт `uploadPending`.
    func uploadPending(raceId: Int) async {
        if inFlight { return }
        inFlight = true
        defer { inFlight = false }
        await flushRace(raceId: raceId)
    }

    /// Оппортунистическая пере-отправка по **каждой** pending-гонке (не только текущий выбор) — так
    /// пики, застрявшие под старой гонкой, всё равно дошлются. Обходит `pendingUploadRaces()`.
    /// Тот же concurrency-guard, что у `uploadPending`. Порт `uploadAllPending`.
    func uploadAllPending() async {
        if inFlight { return }
        inFlight = true
        defer { inFlight = false }
        let races: [Int]
        do {
            races = try await judgeScanStore.pendingUploadRaces()
        } catch {
            judgeScanUploadLog.error("pendingUploadRaces failed: \(String(describing: error))")
            return
        }
        for raceId in races {
            await flushRace(raceId: raceId)
        }
    }

    // MARK: - Дренаж гонки

    /// Слить одну гонку в обе цели по очереди; цикл каждой цели независим от другой. Порт `flushRace`.
    /// Маркировка — простой `markUploadedLocal/Cloud(ids:)` без version-guard (пики иммутабельны).
    private func flushRace(raceId: Int) async {
        let localKind = await drainUploadLoop(
            fetch: { try await self.judgeScanStore.unuploadedLocal(raceId: raceId, limit: Self.uploadBatch) },
            id: { $0.id },
            upload: { batch in
                await self.local.uploadJudgeScans(
                    raceId: raceId, sourceInstallId: self.installId, scans: batch.map(JudgeScanDto.init(from:))
                ).mapSuccess { $0.accepted }
            },
            mark: { _, ids in try await self.judgeScanStore.markUploadedLocal(ids: Array(ids)) }
        )
        if let kind = localKind {
            recordOutcome(raceId: raceId, target: .local, kind: kind)
        }

        let cloudKind = await drainUploadLoop(
            fetch: { try await self.judgeScanStore.unuploadedCloud(raceId: raceId, limit: Self.uploadBatch) },
            id: { $0.id },
            upload: { batch in
                await self.cloud.uploadJudgeScans(
                    raceId: raceId, sourceInstallId: self.installId, scans: batch.map(JudgeScanDto.init(from:))
                ).mapSuccess { $0.accepted }
            },
            mark: { _, ids in try await self.judgeScanStore.markUploadedCloud(ids: Array(ids)) }
        )
        if let kind = cloudKind {
            recordOutcome(raceId: raceId, target: .cloud, kind: kind)
        }
    }

    // MARK: - Публикация исходов

    /// Записать исход одной цели гонки с меткой стенных часов и опубликовать снимок (дедуп равных).
    private func recordOutcome(raceId: Int, target: UploadTarget, kind: UploadResultKind) {
        var byTarget = outcomes[raceId] ?? [:]
        byTarget[target] = TargetUploadOutcome(kind: kind, atWallMs: wallNow())
        outcomes[raceId] = byTarget
        publish()
    }

    /// Опубликовать текущий снимок `outcomes`, дедупя равные значения (как `MutableStateFlow`).
    private func publish() {
        guard outcomes != lastPublished else { return }
        lastPublished = outcomes
        continuation.yield(outcomes)
    }
}
