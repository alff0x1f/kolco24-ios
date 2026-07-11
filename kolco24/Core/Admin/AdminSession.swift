//
//  AdminSession.swift
//  kolco24
//
//  Чистое ядро admin-сессии. Порт value-части `data/AdminAuthRepository.kt`: сам тип сессии
//  (`AdminSession` sealed → Swift `enum`), лексикографический `isExpired`, форматтер `nowUtcIso`,
//  `LoginOutcome` и русские строки `adminErrorMessage`. Сетевые переходы (login/logout/onUnauthorized)
//  и маппинг `PostResult → LoginOutcome` живут в репозитории (Task 4 — `Core/` не зависит от `Net/`).
//
//  `Core/Admin/` — Foundation-only (grep-инвариант этапа 9/10): без `UIKit`/`SwiftUI`/`GRDB`/сетей.
//

import Foundation

/// Состояние admin-сессии организатора. [loggedOut] — покой; [loggedIn] несёт opaque 30-дневный
/// bearer [token] (для подписного интерцептора), [email] для UI и сырую ISO-строку [expiresAt] от
/// сервера (UTC, `Z`-суффикс) для ленивой проверки протухания.
enum AdminSession: Equatable {
    case loggedOut
    case loggedIn(email: String, token: String, expiresAt: String)
}

/// Итог `AdminAuthRepository.login`, показываемый форме входа.
enum LoginOutcome: Equatable {
    case success
    case invalidCredentials
    case rateLimited
    case offline
    case error
}

/// Пользовательская русская строка для неуспешного [outcome] (`nil` для [LoginOutcome.success]).
/// Строки — **дословно** из Kotlin `adminErrorMessage` (`AdminAuthRepository.kt`), зеркальный тест
/// ассертит их байт-в-байт.
func adminErrorMessage(_ outcome: LoginOutcome) -> String? {
    switch outcome {
    case .success:
        return nil
    // Намеренно неоднозначно: никогда не раскрываем, email или пароль был неверным.
    case .invalidCredentials:
        return "Неверный email или пароль"
    case .rateLimited:
        return "Слишком много попыток входа. Попробуйте позже"
    case .offline:
        return "Нет соединения с сервером"
    case .error:
        return "Не удалось войти. Попробуйте ещё раз"
    }
}

/// Протух ли [expiresAt] на момент [nowUtcIso]. Обе строки — фиксированной ширины UTC вида
/// `yyyy-MM-dd'T'HH:mm:ss'Z'`, поэтому обычное лексикографическое сравнение корректно (без
/// `java.time`/`Date`-парсинга). Граница строгого равенства считается **истёкшей**.
func isExpired(expiresAt: String, nowUtcIso: String) -> Bool {
    nowUtcIso >= expiresAt
}

/// [date] форматируется в фиксированной ширины UTC-строку `yyyy-MM-dd'T'HH:mm:ss'Z'` (см. [isExpired]).
/// Точная форма серверного `expires_at`, так что две строки сравниваются лексикографически.
func nowUtcIso(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    return formatter.string(from: date)
}
