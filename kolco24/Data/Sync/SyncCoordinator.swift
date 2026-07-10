//
//  SyncCoordinator.swift
//  kolco24
//
//  Порт `data/sync/SyncCoordinator.kt` — тонкая оркестрация переключения LAN-режима и его
//  pin-aware автосинков. Сама lease-математика живёт в чистом `Core/Lease/RaceLease.swift`
//  (`applySyncResponse`/`isPinned`) — этот тип только секвенирует вызовы и исполняет их исходы.
//
//  **Не 1:1 по структуре:** тип — `actor` (прецедент `MarkUploadRepository`), но одной actor-изоляции
//  для котлиновского `leaseMutex` НЕ хватает: изоляция снимается на каждом `await`, поэтому
//  read-decide-write последовательности (`probeLocalAndRenew`, `enterLocalMode`/`exitLocalMode`),
//  охватывающие `await fetchSync`/`await fanOut`, без явного замка НЕ были бы взаимоисключающими —
//  Kotlin-`Mutex.withLock` держится ПОПЕРЁК suspend'ов. Поэтому эти три метода берут внутренний
//  async-замок (`lockLease`/`unlockLease`: переживает await, FIFO-честный прямой hand-off) — он и
//  воспроизводит семантику `leaseMutex`. Без него stale in-flight `Renew` пробы мог бы лечь после
//  явного `exitLocalMode()` и молча ре-пинить гонку, которую пользователь только что открепил.
//
//  Каждая зависимость — замыкание-seam (идиома `ApiClient`/`ScanModel`), так что `SyncCoordinatorTests`
//  инжектит фейки без БД/сети. Координатор — под `Data/`, потому `SyncManifestDto` (`Net/Dto/`) ему
//  виден: он разбирает поля манифеста и передаёт их в чистый `applySyncResponse` (прецедент
//  `PhotoFrameInput`). Никакого UIKit/SwiftUI/GRDB.
//

import Foundation

/// Toast-facing исход `SyncCoordinator.enterLocalMode`/`exitLocalMode`.
enum LocalModeOutcome: Equatable {
    /// Включение запинило до [expiresAtMs]; 4 ресурса обновлены с LAN. [dataStale] `true`, когда пин
    /// сам удался, но LAN fan-out — нет (например, кратковременный обрыв Wi-Fi сразу после успешной
    /// пробы sync-манифеста): тост не должен утверждать, что свежие данные легли.
    case pinnedUntil(expiresAtMs: Int64, dataStale: Bool)

    /// LAN доступен, но отказался от авторитета (`data_source == "cloud"`) — обновились с cloud.
    case localNoPin

    /// LAN недоступен при включении — ничего не записано, пин не тронут.
    case localUnreachable

    /// Выключение (или no-pin fallback) — cloud-refresh завершился (с новыми данными или без).
    case cloudUpdated

    /// Выключение — cloud-refresh не нашёл связи вовсе.
    case offline

    /// Гонку разрешить не удалось (нет выбора, пустой кэш, и LAN не смог её выдать).
    case noRace
}

/// Явный порядок серьёзности для свёртки пер-ресурсных [RefreshResult] fan-out'а в один исход тоста:
/// жёсткая ошибка старше мягкой, а любая реальная попытка старше guard-пропуска.
private func severity(_ result: RefreshResult) -> Int {
    switch result {
    case .httpError: return 5
    case .forbidden: return 4
    case .offline: return 3
    case .updated: return 2
    case .notModified: return 1
    case .skipped: return 0
    }
}

/// Сворачивает результаты fan-out'а в один самый серьёзный; пустой вход — вакуумно `.skipped`.
func combineRefreshResults(_ results: [RefreshResult]) -> RefreshResult {
    results.max { severity($0) < severity($1) } ?? .skipped
}

/// Fan-out засчитан как реально доставивший данные (или легитимный no-op) на этих серьёзностях.
private func isFanOutSuccess(_ result: RefreshResult) -> Bool {
    switch result {
    case .updated, .notModified, .skipped: return true
    default: return false
    }
}

/// Тонкая оркестрация LAN-переключения. Все зависимости — `@Sendable`-замыкания (`let`, доступны из
/// `nonisolated sourceFor` без actor-hop): чтения lease/времени синхронны, сетевые пробы/рефреши — async.
///
/// - Parameters:
///   - readLease: синхронное чтение текущего lease (геттер `LeaseHolder.value`).
///   - writeLease: персист обновлённого lease или `nil` для снятия пина (state + write-through в prefs).
///   - nowMs: источник времени lease (wall clock — `isPinned` нужен синхронно).
///   - fetchSync: одна LAN-проба sync-манифеста; любой не-2xx/недоступность сворачивает в `nil`
///     (чистый `applySyncResponse` трактует `nil`-манифест как недоступность/ошибку → `.keep`).
///   - selectedRaceId: гонка выбранной команды, если есть.
///   - cachedRaces: оффлайн-читаемый список гонок (для `nearestRaceId`, когда ничего не выбрано).
///   - refreshRaces/refreshTeams/refreshLegend/refreshMemberTags: 4 пер-source refresh-вызова.
actor SyncCoordinator {
    private let readLease: @Sendable () -> RaceLease?
    private let writeLease: @Sendable (RaceLease?) -> Void
    private let nowMs: @Sendable () -> Int64
    private let fetchSync: @Sendable (Int) async -> SyncManifestDto?
    private let selectedRaceId: @Sendable () async -> Int?
    private let cachedRaces: @Sendable () async -> [Race]
    private let refreshRaces: @Sendable (SyncSource) async -> RefreshResult
    private let refreshTeams: @Sendable (Int, SyncSource) async -> RefreshResult
    private let refreshLegend: @Sendable (Int, SyncSource) async -> RefreshResult
    private let refreshMemberTags: @Sendable (Int, SyncSource) async -> RefreshResult

    init(
        readLease: @escaping @Sendable () -> RaceLease?,
        writeLease: @escaping @Sendable (RaceLease?) -> Void,
        nowMs: @escaping @Sendable () -> Int64,
        fetchSync: @escaping @Sendable (Int) async -> SyncManifestDto?,
        selectedRaceId: @escaping @Sendable () async -> Int?,
        cachedRaces: @escaping @Sendable () async -> [Race],
        refreshRaces: @escaping @Sendable (SyncSource) async -> RefreshResult,
        refreshTeams: @escaping @Sendable (Int, SyncSource) async -> RefreshResult,
        refreshLegend: @escaping @Sendable (Int, SyncSource) async -> RefreshResult,
        refreshMemberTags: @escaping @Sendable (Int, SyncSource) async -> RefreshResult
    ) {
        self.readLease = readLease
        self.writeLease = writeLease
        self.nowMs = nowMs
        self.fetchSync = fetchSync
        self.selectedRaceId = selectedRaceId
        self.cachedRaces = cachedRaces
        self.refreshRaces = refreshRaces
        self.refreshTeams = refreshTeams
        self.refreshLegend = refreshLegend
        self.refreshMemberTags = refreshMemberTags
    }

    // MARK: - Lease-замок (сериализация, переживающая await)
    //
    // Изоляция `actor` снимается на каждом `await`, поэтому read-decide-write последовательности
    // (`probeLocalAndRenew`/`enterLocalMode`/`exitLocalMode`), охватывающие `await fetchSync`/
    // `await fanOut`, без этого замка НЕ были бы взаимоисключающими — котлиновский `leaseMutex.withLock`
    // держится ПОПЕРЁК suspend'ов. Прямой FIFO-честный hand-off владения: `unlockLease` возобновляет
    // следующего ожидающего, НЕ сбрасывая `leaseLocked` (владение передаётся напрямую, без гонки за
    // замок между resume и его подхватом).
    private var leaseLocked = false
    private var leaseWaiters: [Waiter] = []
    private var nextWaiterId: UInt64 = 0

    /// Один ожидающий замка. `cont` обнуляется в момент разрешения (hand-off ИЛИ отмена), так что
    /// продолжение возобновляется РОВНО раз — гонка «hand-off vs cancel» безопасна (кто первый обнулил,
    /// тот и резюмировал; второй видит `nil` и пропускает).
    private final class Waiter {
        let id: UInt64
        var cont: CheckedContinuation<Bool, Never>?
        init(id: UInt64, cont: CheckedContinuation<Bool, Never>) { self.id = id; self.cont = cont }
    }

    /// Берёт lease-замок, переживая await. Возвращает `true`, если владение получено; `false`, если
    /// ожидание было ОТМЕНЕНО (задача-подписчик `selectedTeamStore` пересоздаётся, тумблер уходит) —
    /// тогда вызывающий обязан выйти БЕЗ `unlockLease()` (владения он не получил). Cancellation-aware:
    /// котлиновский `Mutex.withLock` снимает/отменяет ожидающих при отмене; здесь то же — отменённый
    /// ждущий убирается из `leaseWaiters` и не может позже провести сетевые/lease-мутации.
    private func lockLease() async -> Bool {
        if !leaseLocked {
            leaseLocked = true
            return true
        }
        let id = nextWaiterId
        nextWaiterId &+= 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                // Тело suspend'а исполняется в actor-изоляции. Уже отменён на входе → не подвешиваемся.
                if Task.isCancelled {
                    cont.resume(returning: false)
                } else {
                    leaseWaiters.append(Waiter(id: id, cont: cont))
                }
            }
        } onCancel: {
            // Хендлер вне actor-изоляции — возврат в actor через unstructured Task (сам не отменяем).
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Снимает отменённого ждущего с `id` (если ещё в очереди) и резюмирует его `false`. No-op, если
    /// его уже подхватил hand-off (`unlockLease`) — двойного resume нет (`cont` уже `nil`).
    private func cancelWaiter(_ id: UInt64) {
        guard let idx = leaseWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = leaseWaiters.remove(at: idx)
        if let cont = waiter.cont {
            waiter.cont = nil
            cont.resume(returning: false)
        }
    }

    private func unlockLease() {
        // Прямой hand-off владения: возобновляем следующего ЖИВОГО ждущего (`leaseLocked` остаётся true).
        // Пропускаем уже отменённых (их `cont == nil` / их уберёт `cancelWaiter`) — берём первого живого.
        while !leaseWaiters.isEmpty {
            let waiter = leaseWaiters.removeFirst()
            if let cont = waiter.cont {
                waiter.cont = nil
                cont.resume(returning: true) // hand-off: владение передано напрямую
                return
            }
        }
        leaseLocked = false
    }

    /// `.local`, когда [raceId] сейчас запинен, иначе `.cloud`. `nonisolated` — замыкания
    /// (`readLease`/`nowMs`) синхронны, actor-hop не нужен (репозитории читают источник синхронно).
    nonisolated func sourceFor(_ raceId: Int) -> SyncSource {
        isPinned(readLease(), raceId: raceId, nowMs: nowMs()) ? .local : .cloud
    }

    /// Разбирает манифест в `LeaseAction` через чистый `applySyncResponse` (`nil`-манифест → `race: nil`).
    private func leaseAction(for manifest: SyncManifestDto?, raceId: Int) -> LeaseAction {
        applySyncResponse(
            race: manifest?.race,
            dataSource: manifest?.dataSource,
            ttlSec: manifest?.leaseTtlSeconds,
            expiresAtSec: manifest?.leaseExpiresAt,
            raceId: raceId,
            nowMs: nowMs()
        )
    }

    /// Один LAN heartbeat: пробует sync-манифест и применяет `LeaseAction` к сохранённому lease
    /// (renew / clear на handback / keep на ошибке). Три точки пробы — включение, Launch B под пином,
    /// pull-to-refresh под пином.
    @discardableResult
    func probeLocalAndRenew(_ raceId: Int) async -> LeaseAction {
        // Отмена в ожидании замка → выходим без владения (и без `unlockLease`): lease не трогаем.
        guard await lockLease() else { return .keep }
        defer { unlockLease() }
        // Владение могло достаться отменённой задаче через hand-off (гонка `unlockLease` vs `cancelWaiter`):
        // не мутируем lease под отменой — `defer` корректно передаст замок дальше.
        if Task.isCancelled { return .keep }
        let manifest = await fetchSync(raceId)
        let action = leaseAction(for: manifest, raceId: raceId)
        switch action {
        case .renew(let lease):
            writeLease(lease)
        case .clear:
            writeLease(nil)
        case .keep:
            break
        }
        return action
    }

    /// Поток включения: резолвит гонку (гонка выбранной команды, иначе ближайшая из кэша — при пустом
    /// кэше сперва тянет races с LAN), пробует LAN-манифест и либо пинит + рефрешит с LAN, либо
    /// (манифест доступен, но не `local`, вкл. нераспознанный `data_source`) рефрешит с cloud без пина,
    /// либо — LAN недоступен — не пишет ничего.
    func enterLocalMode() async -> LocalModeOutcome {
        // Отмена в ожидании замка → выходим без владения (и без `unlockLease`): ничего не записано,
        // пин не тронут — ровно семантика `.localUnreachable`.
        guard await lockLease() else { return .localUnreachable }
        defer { unlockLease() }
        // Hand-off отменённой задаче (гонка `unlockLease` vs `cancelWaiter`) → не пишем ничего под отменой.
        if Task.isCancelled { return .localUnreachable }
        let selected = await selectedRaceId()
        var races = await cachedRaces()
        if selected == nil, races.isEmpty {
            // Свежая установка / пустой кэш: сбой самого LAN-pull'а (а не «в нём просто нет гонок»)
            // должен всплыть как LocalUnreachable, а не общий NoRace — это ровно сценарий
            // «нет интернета, свежая установка», на который фича и рассчитана.
            let racesResult = await refreshRaces(.local)
            races = await cachedRaces()
            if races.isEmpty, racesResult != .updated, racesResult != .notModified {
                return .localUnreachable
            }
        }
        guard let raceId = selected ?? nearestRaceId(races, today: todayIso()) else {
            return .noRace
        }
        let manifest = await fetchSync(raceId)
        switch leaseAction(for: manifest, raceId: raceId) {
        case .renew(let lease):
            if isPinned(lease, raceId: raceId, nowMs: nowMs()) {
                writeLease(lease)
                let results = await fanOut(raceId, .local)
                // Пин может удаться, а LAN fan-out — провалиться (кратковременный обрыв сразу после
                // успешной пробы манифеста): тост не должен утверждать, что свежие данные легли.
                let dataStale = !isFanOutSuccess(combineRefreshResults(results))
                return .pinnedUntil(expiresAtMs: lease.expiresAtMs, dataStale: dataStale)
            } else {
                // Собственный серверный lease уже истёк на приёме — никогда не показываем «pinned»,
                // который на деле не активен; откат как в no-pin ветке.
                writeLease(nil)
                _ = await fanOut(raceId, .cloud)
                return .localNoPin
            }
        case .clear:
            writeLease(nil)
            _ = await fanOut(raceId, .cloud)
            return .localNoPin
        case .keep:
            if manifest == nil {
                return .localUnreachable
            } else {
                // Доступен, но не `local`/`cloud` для этой гонки (нераспознанный data_source или
                // несовпадение гонки) — никогда не пинимся на мусор; откат на cloud.
                _ = await fanOut(raceId, .cloud)
                return .localNoPin
            }
        }
    }

    /// Поток выключения: безусловно снимает lease, затем рефрешит с cloud в фоне.
    func exitLocalMode() async -> LocalModeOutcome {
        // Отмена в ожидании замка → выходим без владения (и без `unlockLease`): пин не снят, сети не было.
        guard await lockLease() else { return .offline }
        defer { unlockLease() }
        // Hand-off отменённой задаче (гонка `unlockLease` vs `cancelWaiter`) → не снимаем пин под отменой.
        if Task.isCancelled { return .offline }
        writeLease(nil)
        let raceId: Int?
        if let selected = await selectedRaceId() {
            raceId = selected
        } else {
            raceId = nearestRaceId(await cachedRaces(), today: todayIso())
        }
        let results: [RefreshResult]
        if let raceId {
            results = await fanOut(raceId, .cloud)
        } else {
            results = [await refreshRaces(.cloud)]
        }
        // 403/5xx не должен отчитываться как успех рядом с реальным офлайном — только настоящий
        // update/no-change/guard-skip считается `CloudUpdated`.
        return isFanOutSuccess(combineRefreshResults(results)) ? .cloudUpdated : .offline
    }

    /// Тело pull-to-refresh: под пином сперва пробует LAN (heartbeat + мгновенная детекция handback),
    /// затем fan-out через **перечитанный** `sourceFor` — проба могла только что снять пин.
    func refreshAll(_ raceId: Int) async -> RefreshResult {
        if sourceFor(raceId) == .local {
            await probeLocalAndRenew(raceId)
        }
        return combineRefreshResults(await fanOut(raceId, sourceFor(raceId)))
    }

    /// 4 рефреша параллельно (`async let`, ошибки — значения `RefreshResult`, изоляция сбоев).
    private func fanOut(_ raceId: Int, _ source: SyncSource) async -> [RefreshResult] {
        async let races = refreshRaces(source)
        async let teams = refreshTeams(raceId, source)
        async let legend = refreshLegend(raceId, source)
        async let memberTags = refreshMemberTags(raceId, source)
        return await [races, teams, legend, memberTags]
    }
}
