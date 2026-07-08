//
//  ScanSession.swift
//  kolco24
//
//  Стейт-машина 20-секундного окна «Отметить КП». Порт 1:1 чистой логики из
//  `ui/scan/ScanSession.kt` — value-тип сессии, классификация тапа в `ScanEvent`,
//  свёртка события в сессию, проверки окна/завершённости. Никакого Android, I/O
//  или таймера: хост владеет часами и записями в БД, здесь только описание
//  «что просканировано».
//
//  Зависимости (готовы предыдущими задачами): `UnlockOutcome` (Model/),
//  `Checkpoint` (Model/), `chipCodeHex` (Core/Nfc/ChipRecord.swift).
//

import Foundation

/// Длительность скользящего скан-окна в миллисекундах. Общая для UI-таймера
/// ScanScreen и серверной проверки истечения на стороне БД.
let SCAN_WINDOW_MS: Int64 = 20_000

/// Истекло ли 20-секундное скользящее окно между [lastScanAt] и [now]?
///
/// Оба аргумента — **монотонные** `elapsedRealtime` мс (иммунны к сдвигу
/// настенных часов). `nil` [lastScanAt] (ещё не было сканов) никогда не истекает.
/// Граница `>=`: ровно [SCAN_WINDOW_MS] после последнего скана считается
/// истёкшим (зеркало прежнего `>=` гварда хоста).
func isWindowExpired(lastScanAt: Int64?, now: Int64) -> Bool {
    guard let lastScanAt else { return false }
    return (now - lastScanAt) >= SCAN_WINDOW_MS
}

/// In-flight состояние одной сессии «Отметить КП» — скользящее 20-секундное окно,
/// накапливающее present-множество команды вокруг одного чипа КП. Чистый
/// value-тип: без Android, I/O, таймера.
///
/// Чип КП и браслеты участников сканируются в любом порядке. Пока чип КП не
/// прочитан ([checkpointId] == nil), сканы участников копятся в
/// [bufferedBeforeKp]; как только КП приходит, буфер сливается в [present] (см.
/// [reduce]). [lastScanAt] — **монотонные** `elapsedRealtime` мс последнего
/// **принятого** скана, двигающие окно: скан `unboundChip`/`badKp` игнорируется
/// и **не** продвигает его.
struct ScanSession: Equatable {
    let checkpointId: Int?
    let checkpointNumber: Int?
    let cost: Int?
    let cpUid: String?
    let cpCode: String?
    let present: Set<Int>
    let bufferedBeforeKp: Set<Int>
    let lastScanAt: Int64

    /// Свежая сессия без КП и участников, помеченная [now] первого скана.
    static func empty(now: Int64) -> ScanSession {
        ScanSession(
            checkpointId: nil,
            checkpointNumber: nil,
            cost: nil,
            cpUid: nil,
            cpCode: nil,
            present: [],
            bufferedBeforeKp: [],
            lastScanAt: now
        )
    }

    /// Копия с частичной заменой полей (аналог Kotlin `copy`).
    fileprivate func copy(
        checkpointId: Int?? = nil,
        checkpointNumber: Int?? = nil,
        cost: Int?? = nil,
        cpUid: String?? = nil,
        cpCode: String?? = nil,
        present: Set<Int>? = nil,
        bufferedBeforeKp: Set<Int>? = nil,
        lastScanAt: Int64? = nil
    ) -> ScanSession {
        ScanSession(
            checkpointId: checkpointId ?? self.checkpointId,
            checkpointNumber: checkpointNumber ?? self.checkpointNumber,
            cost: cost ?? self.cost,
            cpUid: cpUid ?? self.cpUid,
            cpCode: cpCode ?? self.cpCode,
            present: present ?? self.present,
            bufferedBeforeKp: bufferedBeforeKp ?? self.bufferedBeforeKp,
            lastScanAt: lastScanAt ?? self.lastScanAt
        )
    }
}

/// Классифицированный итог одного NFC-тапа, решённый чисто [classifyTag]. Только
/// [kp] и [member] продвигают сессию; [unboundChip] и [badKp] — диагностика,
/// которую UI показывает, не трогая окно.
enum ScanEvent: Equatable {
    /// Чип КП: идентифицирует [checkpointId] с распознанными [number]/[cost] и
    /// анти-чит логом.
    case kp(checkpointId: Int, number: Int, cost: Int, cpUid: String, cpCode: String)

    /// Привязанный браслет участника ([numberInTeam] — слот участника в ростере).
    case member(numberInTeam: Int)

    /// Браслет, чей uid не привязан ни к одному участнику текущей команды.
    case unboundChip

    /// Чип КП, который не удалось превратить в пригодный [kp] (неизвестный /
    /// крипто-фейл / нет легенды).
    case badKp(reason: String)
}

/// Свёртывает одно [event] в [session] на момент [now] (монотонные
/// `elapsedRealtime` мс). Чистая; единственная стейт-машина скан-флоу.
///
/// - [ScanEvent.kp] заполняет поля КП и **сливает** [ScanSession.bufferedBeforeKp]
///   в [ScanSession.present]. Повторный скан того же КП просто перештампывает окно.
/// - [ScanEvent.member] идёт в буфер, пока [ScanSession.checkpointId] == nil,
///   иначе прямо в `present`; set-семантика делает повторного участника
///   идемпотентным. Участник, просканированный без сессии, стартует её.
///   Повторный скан уже учтённого участника **не** обновляет окно.
/// - [ScanEvent.unboundChip] / [ScanEvent.badKp] игнорируются — сессия
///   возвращается без изменений.
func reduce(session: ScanSession?, event: ScanEvent, now: Int64) -> ScanSession? {
    switch event {
    case let .kp(checkpointId, number, cost, cpUid, cpCode):
        let base = session ?? ScanSession.empty(now: now)
        // При переключении на другой КП отбросить участников прежнего КП — они
        // присутствовали на другом пункте. Повтор того же КП сохраняет набор.
        let priorPresent = (session?.checkpointId == checkpointId) ? base.present : Set<Int>()
        return base.copy(
            checkpointId: .some(checkpointId),
            checkpointNumber: .some(number),
            cost: .some(cost),
            cpUid: .some(cpUid),
            cpCode: .some(cpCode),
            present: priorPresent.union(base.bufferedBeforeKp),
            bufferedBeforeKp: [],
            lastScanAt: now
        )

    case let .member(numberInTeam):
        let base = session ?? ScanSession.empty(now: now)
        if base.checkpointId == nil {
            // Уже в буфере → идемпотентно, окно не трогаем.
            if base.bufferedBeforeKp.contains(numberInTeam) { return base }
            return base.copy(
                bufferedBeforeKp: base.bufferedBeforeKp.union([numberInTeam]),
                lastScanAt: now
            )
        } else {
            // Уже present → идемпотентно, окно не трогаем.
            if base.present.contains(numberInTeam) { return base }
            return base.copy(
                present: base.present.union([numberInTeam]),
                lastScanAt: now
            )
        }

    case .unboundChip, .badKp:
        return session
    }
}

/// Классифицирует один NFC-тап в [ScanEvent], чисто (без Android `Tag` I/O, без
/// крипто — вызыватель заранее читает [code]/[uid] чипа и прогоняет
/// [UnlockOutcome]).
///
/// Ненулевой [code] — чип КП: `checkpointId` итога [unlock] резолвится по
/// [checkpointsById] для снапшота [number]/[cost]. Всё ещё `nil` cost (легенда не
/// синхронизирована) деградирует в [ScanEvent.badKp]. `nil` [code] — браслет:
/// поиск в [bindings] (uid → numberInTeam) для [ScanEvent.member] или
/// [ScanEvent.unboundChip].
func classifyTag(
    code: Data?,
    uid: String,
    unlock: UnlockOutcome?,
    bindings: [String: Int],
    checkpointsById: [Int: Checkpoint]
) -> ScanEvent {
    if let code {
        let checkpointId: Int
        switch unlock {
        case let .revealed(id, _):
            checkpointId = id
        case let .identityOnly(id):
            checkpointId = id
        case let .failed(reason):
            return .badKp(reason: reason)
        case .unknown:
            return .badKp(reason: "неизвестный чип")
        case nil:
            return .badKp(reason: "не удалось расшифровать")
        }
        guard let cp = checkpointsById[checkpointId], let cost = cp.cost else {
            return .badKp(reason: "легенда не загружена")
        }
        return .kp(
            checkpointId: checkpointId,
            number: cp.number,
            cost: cost,
            cpUid: uid,
            cpCode: chipCodeHex(code)
        )
    }
    guard let numberInTeam = bindings[uid] else { return .unboundChip }
    return .member(numberInTeam: numberInTeam)
}

/// UI-решение о закрытии: «завершена» ли отметка — КП идентифицирован и все
/// участники ростера present?
///
/// Зеркалит **форму** `present.size >= expectedCount` из `MarkRepository`, но для
/// сугубо косметического решения о закрытии оверлея. Требует
/// [ScanSession.checkpointId] != nil и непустой ростер.
func isComplete(session: ScanSession?, rosterSize: Int) -> Bool {
    guard let session, session.checkpointId != nil else { return false }
    return rosterSize > 0 && session.present.count >= rosterSize
}
