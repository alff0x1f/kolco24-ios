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

/// Сервер admin-сессии. Cloud и LAN-сервер гонки выдают **независимые** токены: cloud-bearer никогда
/// не уходит на cleartext LAN-хост, LAN-bearer — только пока активен lease.
enum AdminServer: Equatable, Sendable {
    case cloud
    case lan
}

/// Куда уходит админ-запрос экрана провижининга, решённое на тап: LAN, пока гонка запинена на LAN,
/// иначе cloud. [hasSession] `false` → тап падает inline без запроса; [onUnauthorized] чистит сессию
/// именно этого сервера.
struct AdminBindRoute {
    let server: AdminServer
    let hasSession: Bool
    let onUnauthorized: () -> Void
}

/// Inline-ошибка тапа провижининга, когда на выбранном сервере нет входа.
func adminNoSessionMessage(_ server: AdminServer) -> String {
    switch server {
    case .cloud: "Нет входа на cloud-сервер"
    case .lan: "Нет входа на LAN-сервер"
    }
}

/// Сворачивает итоги параллельного входа cloud + LAN в один, показываемый формой. Реальный ответ
/// сервера бьёт «недоступен»: в лесу cloud почти всегда `.offline`, и это не должно прятать LAN-овое
/// «неверный пароль». Ранг: success > invalidCredentials > rateLimited > error > offline. Пустой
/// список (ничего не пробовали) → `.error`.
func combinedLoginOutcome(_ outcomes: [LoginOutcome]) -> LoginOutcome {
    let rank: [LoginOutcome] = [.offline, .error, .rateLimited, .invalidCredentials, .success]
    return outcomes.max { rank.firstIndex(of: $0)! < rank.firstIndex(of: $1)! } ?? .error
}

/// Сабтайтл ряда «Администратор» в Настройках: «Войти» без сессий, email при входе на оба сервера
/// (cloud-овый), иначе email + какой сервер единственный.
func adminRowSubtitle(cloud: AdminSession, local: AdminSession) -> String {
    switch (cloud, local) {
    case let (.loggedIn(email, _, _), .loggedIn):
        return email
    case let (.loggedIn(email, _, _), .loggedOut):
        return "\(email) · только Cloud"
    case let (.loggedOut, .loggedIn(email, _, _)):
        return "\(email) · только LAN"
    case (.loggedOut, .loggedOut):
        return "Войти"
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
