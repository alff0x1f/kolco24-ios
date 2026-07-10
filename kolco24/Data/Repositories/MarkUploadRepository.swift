//
//  MarkUploadRepository.swift
//  kolco24
//
//  Порт дренажа выгрузки взятий из `data/MarkRepository.kt` (L280–407, upload-часть) — **не** 1:1
//  по структуре: Kotlin-`Mutex.tryLock()` заменён изоляцией `actor` + флагом `inFlight` (идиома
//  `TrustedClock`), исходы дренажа отдаются через `AsyncStream` (идиома `TrustedClock.statusUpdates`).
//
//  Дренаж идемпотентен и батчируется по обеим целям независимо: для одного скоупа `(raceId, teamId)`
//  сначала Local («Финиш», LAN), потом Cloud («Интернет», HTTPS) — падение одной цели не блокирует
//  другую. Каждая цель прокачивается generic-циклом `drainUploadLoop` (fetch ≤500 → POST → пометить
//  `accepted ∩ batch` version-guard'ом → повтор). Этапы 8/10 переиспользуют `drainUploadLoop` для
//  track/judge со своими `*UploadResponse`, поэтому `upload` возвращает уже извлечённый `accepted`
//  (`PostResult<[String]>`), а не конкретный response-DTO.
//
//  `import GRDB` — файл под `Data/`, потребляет `MarkStore` (GRDB-конформанс) и переиспользует
//  `TrackScope` (Hashable — ключ словаря исходов). Сетевой слой (`ApiClient`/`PostResult`) — из `Net/`.
//

import GRDB
import os

/// Логгер дренажа выгрузки (ошибки БД внутри цикла сворачиваются в `.error` + лог, движок не роняет
/// процесс — конвенция этапа 2 «decode error → fallback + log»).
private let uploadLog = Logger(subsystem: "kolco24", category: "MarkUpload")

/// Свести любой не-`success` `PostResult` к грубому `UploadResultKind`, который показывает строка
/// статуса: `.offline` → `.offline`, всё прочее → `.error`. Зеркало `uploadResultKind` из
/// `TrackModels.kt`. NB: чистый `.success` до этого маппера не доходит (обрабатывается в цикле); а
/// `.success` **без прогресса** — забота цикла (он сам маппит в `.error`).
func uploadResultKind<T>(_ result: PostResult<T>) -> UploadResultKind {
    switch result {
    case .success:
        return .ok
    case .offline:
        return .offline
    default:
        return .error
    }
}

/// Прокачать одну цель батчами до пустого fetch'а или застревания, вернув терминальный
/// `UploadResultKind` либо `nil`. Семантика 1:1 с Kotlin `uploadLoop` (`MarkRepository.kt` L390–407):
///
/// - пустой первый fetch (**нечего слать**) → `nil` (попытки не было);
/// - слил до пустого после хотя бы одной пометки → `.ok`;
/// - не-`success` ответ (offline/ошибка — через `uploadResultKind`, дошлём на следующем триггере) → kind;
/// - **нет прогресса** (ни один id батча не вернулся в `accepted`) → `.error` (а НЕ `.ok`, который дал бы
///   `uploadResultKind(.success)`), защита от зацикливания;
/// - ошибка БД (`fetch`/`mark` бросили) → `.error` + лог (движок не роняет процесс).
///
/// Помечаются только id, которые **и** в `accepted`, **и** в fetched-батче — так странный ответ не
/// пометит строку вне скоупа, а помеченная строка строго уменьшает pending-множество (гарантия выхода).
///
/// - Parameters:
///   - fetch: очередной батч строк-кандидатов (`LIMIT` на стороне запроса).
///   - id: клиентский `id` строки (для пересечения с `accepted`).
///   - upload: POST батча; возвращает уже извлечённый `accepted` (`PostResult<[String]>`).
///   - mark: пометить `accepted ∩ batch` доставленными (version-guard внутри).
func drainUploadLoop<Row>(
    fetch: () async throws -> [Row],
    id: (Row) -> String,
    upload: ([Row]) async -> PostResult<[String]>,
    mark: ([Row], Set<String>) async throws -> Void
) async -> UploadResultKind? {
    var progressed = false
    while true {
        let batch: [Row]
        do {
            batch = try await fetch()
        } catch {
            uploadLog.error("drainUploadLoop fetch failed: \(String(describing: error))")
            return .error
        }
        if batch.isEmpty {
            return progressed ? .ok : nil
        }
        let result = await upload(batch)
        guard case .success(let accepted) = result else {
            return uploadResultKind(result) // Offline / Error
        }
        let batchIds = Set(batch.map(id))
        let toMark = batchIds.intersection(accepted)
        if toMark.isEmpty {
            return .error // нет прогресса → стоп, догоним на следующем триггере
        }
        do {
            try await mark(batch, toMark)
        } catch {
            uploadLog.error("drainUploadLoop mark failed: \(String(describing: error))")
            return .error
        }
        progressed = true
    }
}

/// Идемпотентная батч-выгрузка взятий в обе цели (LAN «Финиш» + облако «Интернет») с независимыми
/// флагами `uploadedLocal`/`uploadedCloud`, self-heal при офлайне/ошибках. `actor`: изоляция + флаг
/// `inFlight` заменяют Kotlin `Mutex.tryLock()` — перекрывающиеся триггеры молча пропускают (проигравший
/// — no-op, следующий триггер догонит). Исходы дренажа копятся в `outcomes` и стримятся через
/// `outcomeUpdates` (идиома `TrustedClock.statusUpdates`).
actor MarkUploadRepository {
    /// Максимум взятий на один запрос (совпадает с `LIMIT` в `unuploaded*`-запросах).
    static let uploadBatch = 500

    private let markStore: MarkStore
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

    /// Последний исход дренажа по каждой цели каждого скоупа. Читается моделью экрана (`await`).
    private(set) var outcomes: [TrackScope: [UploadTarget: TargetUploadOutcome]] = [:]

    /// Поток снимков `outcomes` (полный словарь на каждое изменение; равные снимки дедупятся вручную).
    /// Потребитель — `UploadModel` (этап 6, задача 5). Идиома `TrustedClock.statusUpdates`.
    nonisolated let outcomeUpdates: AsyncStream<[TrackScope: [UploadTarget: TargetUploadOutcome]]>
    private let continuation: AsyncStream<[TrackScope: [UploadTarget: TargetUploadOutcome]]>.Continuation
    /// Последний опубликованный снимок — для ручного дедупа равных значений.
    private var lastPublished: [TrackScope: [UploadTarget: TargetUploadOutcome]] = [:]

    init(
        markStore: MarkStore,
        cloud: ApiClient,
        local: ApiClient,
        installId: String,
        wallNow: @escaping () -> Int64
    ) {
        self.markStore = markStore
        self.cloud = cloud
        self.local = local
        self.installId = installId
        self.wallNow = wallNow

        var cont: AsyncStream<[TrackScope: [UploadTarget: TargetUploadOutcome]]>.Continuation!
        self.outcomeUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        self.continuation = cont
    }

    // MARK: - Входы (tryLock-guard)

    /// Слить все pending-строки одного скоупа `(raceId, teamId)` в обе цели. Guard'ится, чтобы два
    /// прохода не задвоили отправку; проигравший — no-op (следующий триггер догонит). Порт `uploadPending`.
    func uploadPending(raceId: Int, teamId: Int) async {
        if inFlight { return }
        inFlight = true
        defer { inFlight = false }
        await flushScope(raceId: raceId, teamId: teamId)
    }

    /// Оппортунистическая пере-отправка по **каждому** pending-скоупу (не только текущий выбор) — так
    /// строки, застрявшие под старой гонкой/командой, всё равно дошлются. Обходит `pendingUploadScopes()`.
    /// Тот же concurrency-guard, что у `uploadPending`. Порт `uploadAllPending`.
    func uploadAllPending() async {
        if inFlight { return }
        inFlight = true
        defer { inFlight = false }
        let scopes: [TrackScope]
        do {
            scopes = try await markStore.pendingUploadScopes()
        } catch {
            uploadLog.error("pendingUploadScopes failed: \(String(describing: error))")
            return
        }
        for scope in scopes {
            await flushScope(raceId: scope.raceId, teamId: scope.teamId)
        }
    }

    // MARK: - Дренаж скоупа

    /// Слить один скоуп в обе цели по очереди; цикл каждой цели независим от другой. Порт `flushScope`
    /// (в этапе 6 — только metadata-цикл; frame-drain кадров — этап 7, `combineOutcome(meta, nil) == meta`).
    private func flushScope(raceId: Int, teamId: Int) async {
        let scope = TrackScope(raceId: raceId, teamId: teamId)

        let localMeta = await drainUploadLoop(
            fetch: { try await self.markStore.unuploadedLocal(raceId: raceId, teamId: teamId, limit: Self.uploadBatch) },
            id: { $0.id },
            upload: { batch in
                await self.local.uploadMarks(
                    raceId: raceId, teamId: teamId, sourceInstallId: self.installId,
                    marks: batch.map(MarkDto.init(from:))
                ).mapSuccess { $0.accepted }
            },
            mark: { batch, ids in try await self.markLocalGpsAware(batch: batch, ids: ids) }
        )
        if let kind = combineOutcome(localMeta, nil) {
            recordOutcome(scope: scope, target: .local, kind: kind)
        }

        let cloudMeta = await drainUploadLoop(
            fetch: { try await self.markStore.unuploadedCloud(raceId: raceId, teamId: teamId, limit: Self.uploadBatch) },
            id: { $0.id },
            upload: { batch in
                await self.cloud.uploadMarks(
                    raceId: raceId, teamId: teamId, sourceInstallId: self.installId,
                    marks: batch.map(MarkDto.init(from:))
                ).mapSuccess { $0.accepted }
            },
            mark: { batch, ids in try await self.markCloudGpsAware(batch: batch, ids: ids) }
        )
        if let kind = combineOutcome(cloudMeta, nil) {
            recordOutcome(scope: scope, target: .cloud, kind: kind)
        }
    }

    // MARK: - GPS-aware пометка (два ортогональных guard'а)

    /// Пометить строки локально-доставленными с двумя guard'ами на строку: (1) version-guard по
    /// `updatedAt` — если `addMember` мутировал строку между fetch'ем и этим вызовом, пометка не ложится
    /// (строка перевыгрузится с обновлённым `present`); (2) `locLat IS NULL` (только строки без GPS) —
    /// если `attachLocation` записал фикс между сборкой DTO и этим вызовом, строка не помечается
    /// (перевыгрузится с координатой). Guard'ы ортогональны: `addMember` бампит `updatedAt`, но не трогает
    /// `locLat`; `attachLocation` ставит `locLat`, но не бампит `updatedAt`. Порт `markLocalGpsAware`.
    private func markLocalGpsAware(batch: [Mark], ids: Set<String>) async throws {
        let byId = Dictionary(batch.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for id in ids {
            guard let mark = byId[id] else { continue }
            if mark.locLat != nil {
                try await markStore.markUploadedLocalIfUnchanged(id: id, updatedAt: mark.updatedAt)
            } else {
                try await markStore.markUploadedLocalIfUnchangedAndNoLocation(id: id, updatedAt: mark.updatedAt)
            }
        }
    }

    /// Тот же дуал-guard, что `markLocalGpsAware`, для облачной цели. Порт `markCloudGpsAware`.
    private func markCloudGpsAware(batch: [Mark], ids: Set<String>) async throws {
        let byId = Dictionary(batch.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for id in ids {
            guard let mark = byId[id] else { continue }
            if mark.locLat != nil {
                try await markStore.markUploadedCloudIfUnchanged(id: id, updatedAt: mark.updatedAt)
            } else {
                try await markStore.markUploadedCloudIfUnchangedAndNoLocation(id: id, updatedAt: mark.updatedAt)
            }
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

/// Сохранить кейс `PostResult`, преобразовав только payload успеха — так `drainUploadLoop` получает
/// `PostResult<[String]>` (извлечённый `accepted`) без потери информации об ошибке.
private extension PostResult {
    func mapSuccess<U>(_ transform: (T) -> U) -> PostResult<U> {
        switch self {
        case .success(let v): return .success(transform(v))
        case .badRequest: return .badRequest
        case .unauthorized: return .unauthorized
        case .forbidden: return .forbidden
        case .conflict: return .conflict
        case .rateLimited: return .rateLimited
        case .offline: return .offline
        case .error(let code): return .error(code: code)
        }
    }
}
