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
//  Файл под `Data/`, потребляет `MarkStore` и переиспользует `TrackScope` (Hashable — ключ словаря
//  исходов). Сетевой слой (`ApiClient`/`PostResult`) — из `Net/`. Никакой GRDB-тип не пересекает границу
//  (`Row` в `drainUploadLoop` — generic-параметр, а не GRDB `Row`), поэтому `import GRDB` не нужен.
//

import Foundation
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

/// POST кадра, который неприемлем и никогда не пройдёт на ретрае: `400` (битый) или `413` (payload
/// слишком велик — маппится как `.error(413)`). Проводит границу между **per-frame** сбоем (оставить
/// марку pending, идти дальше) и **transient/target-wide** (стоп всего таргета). Зеркало Kotlin
/// `isHardFrameFailure`; используется frame-дренажем `MarkUploadRepository`.
func isHardFrameFailure<T>(_ result: PostResult<T>) -> Bool {
    switch result {
    case .badRequest:
        return true
    case .error(let code):
        return code == 413
    default:
        return false
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
    /// Чтение сырых JPEG-байт кадра по относительному пути (`marks/<markId>/<uuid>.jpg`). Прод — чтение
    /// файла из `PhotoStorage`; `nil` = отсутствующий/нечитаемый файл (кадр остаётся pending). Порт
    /// `PhotoFrameReader` (незавайренный шов → `nil`).
    private let frameReader: (String) -> Data?

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
        wallNow: @escaping () -> Int64,
        frameReader: @escaping (String) -> Data? = { _ in nil }
    ) {
        self.markStore = markStore
        self.cloud = cloud
        self.local = local
        self.installId = installId
        self.wallNow = wallNow
        self.frameReader = frameReader

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

    /// Слить один скоуп в обе цели по очереди; цикл каждой цели независим от другой. Порт `flushScope`:
    /// на каждой цели сначала прокачивается metadata-цикл (взятия), затем frame-дренаж кадров, и оба
    /// исхода сводятся `combineOutcome(meta, frame)` в единственное per-target значение (frame `ok`
    /// никогда не маскирует metadata `error`/`offline`).
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
        let localFrame = await frameDrainLoop(
            fetch: { try await self.markStore.framePendingLocal(raceId: raceId, teamId: teamId, limit: Self.uploadBatch) },
            upload: { markId, frameId, bytes in
                await self.local.uploadMarkPhoto(raceId: raceId, markId: markId, frameId: frameId, bytes: bytes)
            },
            markDone: { id, updatedAt in try await self.markStore.setPhotosUploadedLocalIfUnchanged(id: id, updatedAt: updatedAt) }
        )
        if let kind = combineOutcome(localMeta, localFrame) {
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
        let cloudFrame = await frameDrainLoop(
            fetch: { try await self.markStore.framePendingCloud(raceId: raceId, teamId: teamId, limit: Self.uploadBatch) },
            upload: { markId, frameId, bytes in
                await self.cloud.uploadMarkPhoto(raceId: raceId, markId: markId, frameId: frameId, bytes: bytes)
            },
            markDone: { id, updatedAt in try await self.markStore.setPhotosUploadedCloudIfUnchanged(id: id, updatedAt: updatedAt) }
        )
        if let kind = combineOutcome(cloudMeta, cloudFrame) {
            recordOutcome(scope: scope, target: .cloud, kind: kind)
        }
    }

    // MARK: - Frame-дренаж (по кадрам)

    /// Исход попытки выгрузить все кадры одной марки внутри `frameDrainLoop`.
    private enum FrameMarkResult {
        /// Все кадры приняты (или марка не несёт кадров) — флаг марки можно флипнуть.
        case flipped
        /// Hard per-frame сбой или отсутствующий файл — оставить марку pending, идти к следующей.
        case pending
        /// Transient/target-wide сбой — весь таргет останавливается на этот триггер.
        case stop(UploadResultKind)
    }

    /// Выгрузить каждый кадр одной марки, читая байты через `frameReader`. Пустой `photoPath`
    /// (`"[]"`) слать нечего → сразу `.flipped`. Порт `uploadOneMarksFrames`.
    private func uploadOneMarksFrames(
        _ mark: Mark,
        upload: (String, String, Data) async -> PostResult<Void>
    ) async -> FrameMarkResult {
        for relPath in PhotoPaths.decode(mark.photoPath) {
            guard let bytes = frameReader(relPath) else { return .pending }
            let result = await upload(mark.id, PhotoPaths.frameIdOf(relPath), bytes)
            if case .success = result { continue }
            if isHardFrameFailure(result) { return .pending }
            return .stop(uploadResultKind(result))
        }
        return .flipped
    }

    /// Прокачать кадры одной цели батчами до пустого fetch'а или застревания, вернув терминальный
    /// `UploadResultKind` либо `nil`. Семантика 1:1 с Kotlin `frameDrainLoop` (L425–448):
    ///
    /// - пустой первый fetch (нечего слать) → `nil`;
    /// - transient/target-wide сбой кадра (`.stop`) → немедленный стоп таргета с его kind;
    /// - hard per-frame сбой (`400`/`413`) или отсутствующий файл (`.pending`) → марку пропустить,
    ///   к следующей (одна ядовитая рамка не блокирует последующие хорошие марки);
    /// - все кадры марки приняты (`.flipped`) → version-guard'нутый `markDone` (по `updatedAt`);
    /// - нет прогресса за полный проход (ни одна марка не флипнулась) → `.error` (защита от
    ///   зацикливания: ядовитый/missing-only батч остаётся видимо-pending, а не крутится вечно);
    /// - ошибка БД (`fetch`/`markDone` бросили) → `.error` + лог (движок не роняет процесс).
    private func frameDrainLoop(
        fetch: () async throws -> [Mark],
        upload: (String, String, Data) async -> PostResult<Void>,
        markDone: (String, Int64) async throws -> Void
    ) async -> UploadResultKind? {
        var progressed = false
        while true {
            let batch: [Mark]
            do {
                batch = try await fetch()
            } catch {
                uploadLog.error("frameDrainLoop fetch failed: \(String(describing: error))")
                return .error
            }
            if batch.isEmpty {
                return progressed ? .ok : nil
            }
            var flippedThisPass = false
            for mark in batch {
                switch await uploadOneMarksFrames(mark, upload: upload) {
                case .flipped:
                    do {
                        try await markDone(mark.id, mark.updatedAt)
                    } catch {
                        uploadLog.error("frameDrainLoop markDone failed: \(String(describing: error))")
                        return .error
                    }
                    flippedThisPass = true
                case .pending:
                    continue
                case .stop(let kind):
                    return kind
                }
            }
            if !flippedThisPass {
                return .error // нет прогресса → стоп, догоним на следующем триггере
            }
            progressed = true
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
extension PostResult {
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
