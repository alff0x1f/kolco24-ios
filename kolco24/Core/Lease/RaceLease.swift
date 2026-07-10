//
//  RaceLease.swift
//  kolco24
//
//  Зеркало `data/lease/RaceLease.kt` 1:1: чистая lease-математика LAN-режима. Пин на источник
//  данных одной гонки: строки [raceId] обслуживаются с LAN до [expiresAtMs]. Никакого Android,
//  никакой зависимости от `Net/` — `applySyncResponse` принимает **разобранные поля** манифеста
//  (`race`/`dataSource`/`ttlSec`/`expiresAtSec`), а не `SyncManifestDto` (`Core/` от `Net/` не
//  зависит; манифест-`nil` кодируется `race: nil`); маппинг из DTO — на стороне координатора
//  (прецедент `PhotoFrameInput`).
//

import Foundation

/// Пин на источник данных одной гонки: строки [raceId] обслуживаются с LAN до [expiresAtMs].
struct RaceLease: Equatable {
    let raceId: Int
    let expiresAtMs: Int64
}

/// Клиентская длина lease по умолчанию, пока серверные `lease_ttl_seconds`/`lease_expires_at`
/// заглушены `null`: 12 часов.
let DEFAULT_LEASE_MS: Int64 = 12 * 60 * 60 * 1000

/// Считает обновлённый lease для [raceId] на момент [nowMs]. Приоритет истечения:
/// относительный [serverTtlSec] (иммунен к перекосу часов) → абсолютный [serverLeaseExpiresAtSec]
/// (полагается на вменяемые часы сервера) → [nowMs] + [DEFAULT_LEASE_MS] (оба `nil`, сегодняшняя
/// заглушка).
func renewedLease(raceId: Int, serverTtlSec: Int64?, serverLeaseExpiresAtSec: Int64?, nowMs: Int64) -> RaceLease {
    // Kotlin `Long`-арифметика при переполнении молча оборачивается; Swift `*`/`+` ТРАПят. Огромный,
    // но валидный `lease_ttl_seconds`/`lease_expires_at` из LAN-манифеста не должен ронять приложение —
    // считаем с насыщением (клампом к `Int64.max`/`.min` по знаку результата). Клампнутый lease ведёт
    // себя вменяемо в `isPinned` (`.max` → «практически бессрочный», `.min` → уже просрочен) — краш хуже.
    let expiresAtMs: Int64
    if let serverTtlSec {
        expiresAtMs = saturatingAdd(nowMs, saturatingMul(serverTtlSec, 1000))
    } else if let serverLeaseExpiresAtSec {
        expiresAtMs = saturatingMul(serverLeaseExpiresAtSec, 1000)
    } else {
        expiresAtMs = saturatingAdd(nowMs, DEFAULT_LEASE_MS)
    }
    return RaceLease(raceId: raceId, expiresAtMs: expiresAtMs)
}

/// Умножение с насыщением: при переполнении зажимает к `Int64.max`/`.min` (по знаку результата)
/// вместо трапа Swift-`*`.
private func saturatingMul(_ a: Int64, _ b: Int64) -> Int64 {
    let (result, overflow) = a.multipliedReportingOverflow(by: b)
    guard overflow else { return result }
    return (a < 0) == (b < 0) ? .max : .min
}

/// Сложение с насыщением: при переполнении зажимает к `Int64.max`/`.min` (по знаку слагаемого)
/// вместо трапа Swift-`+`.
private func saturatingAdd(_ a: Int64, _ b: Int64) -> Int64 {
    let (result, overflow) = a.addingReportingOverflow(b)
    guard overflow else { return result }
    return b < 0 ? .min : .max
}

/// `true`, когда [lease] пинит [raceId] и ещё не истёк на момент [nowMs]. Строгое `<` на границе
/// истечения (`nowMs == expiresAtMs` уже не запинено).
func isPinned(_ lease: RaceLease?, raceId: Int, nowMs: Int64) -> Bool {
    guard let lease else { return false }
    return lease.raceId == raceId && nowMs < lease.expiresAtMs
}

/// Что проба sync-манифеста должна сделать с сохранённым lease.
enum LeaseAction: Equatable {
    /// Манифест говорит `local` для пробуемой гонки — обновить пин.
    case renew(RaceLease)
    /// Манифест говорит `cloud` для пробуемой гонки (handback) — снять пин.
    case clear
    /// Ошибка, недоступность, чужая гонка или неизвестный `data_source` — не трогать lease.
    case keep
}

/// Маппит результат пробы манифеста в [LeaseAction]. `race == nil` (недоступность/ошибка,
/// манифест-`nil`), манифест для другой гонки или нераспознанный `dataSource` никогда не обновляют
/// lease — только явные `"local"`/`"cloud"` для пробуемого [raceId] что-либо меняют.
func applySyncResponse(race: Int?, dataSource: String?, ttlSec: Int64?, expiresAtSec: Int64?, raceId: Int, nowMs: Int64) -> LeaseAction {
    guard let race, race == raceId else { return .keep }
    switch dataSource {
    case "local":
        return .renew(renewedLease(raceId: raceId, serverTtlSec: ttlSec, serverLeaseExpiresAtSec: expiresAtSec, nowMs: nowMs))
    case "cloud":
        return .clear
    default:
        return .keep
    }
}
