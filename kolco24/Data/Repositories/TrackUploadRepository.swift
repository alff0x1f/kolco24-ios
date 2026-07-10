//
//  TrackUploadRepository.swift
//  kolco24
//
//  Порт дренажа выгрузки точек GPS-трека из `data/track/TrackRepository.kt` (upload-часть) —
//  **структурный клон** `MarkUploadRepository` (этап 6) БЕЗ frame-цикла / `combineOutcome` /
//  version-guard: точки иммутабельны (нет аналога `addMember`/`attachLocation`), поэтому маркировка
//  — простой `markUploadedLocal/Cloud(ids:)`, а per-target исход — одно значение (только metadata).
//
//  Как и marks: Kotlin-`Mutex.tryLock()` заменён изоляцией `actor` + флагом `inFlight`; исходы
//  дренажа отдаются через `AsyncStream` (идиома `TrustedClock.statusUpdates`). Каждый скоуп
//  `(raceId, teamId)` дренируется в обе цели независимо — сначала Local («Финиш», LAN), потом Cloud
//  («Интернет», HTTPS); каждая цель — generic-циклом `drainUploadLoop` (из `MarkUploadRepository.swift`,
//  fetch ≤500 → POST → пометить `accepted ∩ batch` → повтор).
//
//  Файл под `Data/`; переиспользует `TrackScope`/`drainUploadLoop`/`uploadResultKind` (`MarkUpload…`)
//  и `TrackStore` (этап 2). Никакой GRDB-тип не пересекает границу (`Row` в `drainUploadLoop` —
//  generic-параметр), поэтому `import GRDB` не нужен.
//

import Foundation
import os

/// Логгер дренажа выгрузки трека (ошибки БД внутри цикла сворачиваются в `.error` + лог, движок не
/// роняет процесс — конвенция этапа 2 «decode error → fallback + log»).
private let trackUploadLog = Logger(subsystem: "kolco24", category: "TrackUpload")

/// Идемпотентная батч-выгрузка точек GPS-трека в обе цели (LAN «Финиш» + облако «Интернет») с
/// независимыми флагами `uploadedLocal`/`uploadedCloud`, self-heal при офлайне/ошибках. `actor`:
/// изоляция + флаг `inFlight` заменяют Kotlin `Mutex.tryLock()` — перекрывающиеся триггеры молча
/// пропускают (проигравший — no-op, следующий триггер догонит). Исходы дренажа копятся в `outcomes`
/// и стримятся через `outcomeUpdates` (идиома `TrustedClock.statusUpdates`).
actor TrackUploadRepository {
    /// Максимум точек на один запрос (совпадает с `LIMIT` в `unuploaded*`-запросах).
    static let uploadBatch = 500

    private let trackStore: TrackStore
    /// Облачный клиент (HTTPS) — цель `.cloud`.
    private let cloud: ApiClient
    /// LAN-клиент (таймаут 3 с) — цель `.local`; вне сети быстро фейлится в `.offline`.
    private let local: ApiClient
    /// Метка стенных часов исхода (для строки «N мин назад»); инжектится ради управляемого времени в тестах.
    private let wallNow: () -> Int64

    /// tryLock-аналог: пока один проход идёт, перекрывающийся триггер выходит no-op'ом.
    private var inFlight = false

    /// Последний исход дренажа по каждой цели каждого скоупа. Читается моделью экрана (`await`).
    private(set) var outcomes: [TrackScope: [UploadTarget: TargetUploadOutcome]] = [:]

    /// Поток снимков `outcomes` (полный словарь на каждое изменение; равные снимки дедупятся вручную).
    /// Потребитель — `UploadModel` (этап 8, задача 8). Идиома `TrustedClock.statusUpdates`.
    nonisolated let outcomeUpdates: AsyncStream<[TrackScope: [UploadTarget: TargetUploadOutcome]]>
    private let continuation: AsyncStream<[TrackScope: [UploadTarget: TargetUploadOutcome]]>.Continuation
    /// Последний опубликованный снимок — для ручного дедупа равных значений.
    private var lastPublished: [TrackScope: [UploadTarget: TargetUploadOutcome]] = [:]

    init(
        trackStore: TrackStore,
        cloud: ApiClient,
        local: ApiClient,
        wallNow: @escaping () -> Int64
    ) {
        self.trackStore = trackStore
        self.cloud = cloud
        self.local = local
        self.wallNow = wallNow

        var cont: AsyncStream<[TrackScope: [UploadTarget: TargetUploadOutcome]]>.Continuation!
        self.outcomeUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        self.continuation = cont
    }

    // MARK: - Входы (tryLock-guard)

    /// Слить все pending-точки одного скоупа `(raceId, teamId)` в обе цели. Guard'ится, чтобы два
    /// прохода не задвоили отправку; проигравший — no-op (следующий триггер догонит). Порт `uploadPending`.
    func uploadPending(raceId: Int, teamId: Int) async {
        if inFlight { return }
        inFlight = true
        defer { inFlight = false }
        await flushScope(raceId: raceId, teamId: teamId)
    }

    /// Оппортунистическая пере-отправка по **каждому** pending-скоупу (не только текущий выбор) — так
    /// точки, застрявшие под старой гонкой/командой, всё равно дошлются. Обходит `pendingUploadScopes()`.
    /// Тот же concurrency-guard, что у `uploadPending`. Порт `uploadAllPending`.
    func uploadAllPending() async {
        if inFlight { return }
        inFlight = true
        defer { inFlight = false }
        let scopes: [TrackScope]
        do {
            scopes = try await trackStore.pendingUploadScopes()
        } catch {
            trackUploadLog.error("pendingUploadScopes failed: \(String(describing: error))")
            return
        }
        for scope in scopes {
            await flushScope(raceId: scope.raceId, teamId: scope.teamId)
        }
    }

    // MARK: - Дренаж скоупа

    /// Слить один скоуп в обе цели по очереди; цикл каждой цели независим от другой. Порт `flushScope`
    /// (без frame-цикла — трек несёт только «метаданные» точек). Маркировка — простой
    /// `markUploadedLocal/Cloud(ids:)` без version-guard (точки иммутабельны).
    private func flushScope(raceId: Int, teamId: Int) async {
        let scope = TrackScope(raceId: raceId, teamId: teamId)

        let localKind = await drainUploadLoop(
            fetch: { try await self.trackStore.unuploadedLocal(raceId: raceId, teamId: teamId, limit: Self.uploadBatch) },
            id: { $0.id },
            upload: { batch in
                await self.local.uploadTrack(
                    raceId: raceId, teamId: teamId, points: batch.map(TrackPointDto.init(from:))
                ).mapSuccess { $0.accepted }
            },
            mark: { _, ids in try await self.trackStore.markUploadedLocal(ids: Array(ids)) }
        )
        if let kind = localKind {
            recordOutcome(scope: scope, target: .local, kind: kind)
        }

        let cloudKind = await drainUploadLoop(
            fetch: { try await self.trackStore.unuploadedCloud(raceId: raceId, teamId: teamId, limit: Self.uploadBatch) },
            id: { $0.id },
            upload: { batch in
                await self.cloud.uploadTrack(
                    raceId: raceId, teamId: teamId, points: batch.map(TrackPointDto.init(from:))
                ).mapSuccess { $0.accepted }
            },
            mark: { _, ids in try await self.trackStore.markUploadedCloud(ids: Array(ids)) }
        )
        if let kind = cloudKind {
            recordOutcome(scope: scope, target: .cloud, kind: kind)
        }
    }

    // MARK: - Публикация исходов

    /// Записать исход одной цели скоупа с меткой стенных часов и опубликовать снимок (дедуп равных).
    private func recordOutcome(scope: TrackScope, target: UploadTarget, kind: UploadResultKind) {
        var byTarget = outcomes[scope] ?? [:]
        byTarget[target] = TargetUploadOutcome(kind: kind, atWallMs: wallNow())
        outcomes[scope] = byTarget
        publish()
    }

    /// Опубликовать текущий снимок `outcomes`, дедупя равные значения (как `MutableStateFlow`).
    private func publish() {
        guard outcomes != lastPublished else { return }
        lastPublished = outcomes
        continuation.yield(outcomes)
    }
}

// `PostResult.mapSuccess` (извлечение `accepted` без потери кейса ошибки) — общий с `MarkUploadRepository`
// (там `extension PostResult`, module-internal); отдельного дубликата здесь больше нет.
