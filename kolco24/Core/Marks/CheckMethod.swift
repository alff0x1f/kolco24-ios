//
//  CheckMethod.swift
//  kolco24
//
//  iOS-only (Android `check_method` не обрабатывает — Kotlin-источника нет).
//  Способ проверки взятия КП, снимок `Tag.checkMethod` на строке взятия
//  (`Mark.checkMethod`):
//  - `offline` — complete-взятие идёт в зачёт как раньше;
//  - `cloud` / `local` — взятие идёт в зачёт, только если облачный / локальный
//    (LAN) сервер принял отметку, пока скан-лист был открыт (`Mark.confirmedAt`).
//
//  Единое чистое правило [isCounted] заменяет `complete` во всех деривациях
//  очков и «взято».
//

import Foundation

/// Способ проверки взятия КП. Неизвестные / старые значения читаются как
/// [offline] (обратная совместимость: `online` / `local_server` / `nfc` / пусто).
enum CheckMethod: String, Equatable {
    case offline
    case cloud
    case local

    /// Разбор wire-строки; неизвестное / пустое значение — [offline].
    init(_ raw: String) {
        self = CheckMethod(rawValue: raw) ?? .offline
    }

    /// Сервер, который должен подтвердить взятие; `nil` для offline.
    var uploadTarget: UploadTarget? {
        switch self {
        case .offline: return nil
        case .cloud: return .cloud
        case .local: return .local
        }
    }
}

/// Взятие идёт в зачёт: complete и (offline или подтверждено сервером).
func isCounted(_ m: Mark) -> Bool {
    m.complete && (CheckMethod(m.checkMethod) == .offline || m.confirmedAt != nil)
}

/// Complete-взятие cloud/local КП, которое сервер не подтвердил: тайл остаётся,
/// но в зачёт не идёт.
func isUnconfirmed(_ m: Mark) -> Bool {
    m.complete && !isCounted(m)
}
