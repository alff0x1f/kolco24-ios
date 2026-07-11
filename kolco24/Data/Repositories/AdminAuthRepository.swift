//
//  AdminAuthRepository.swift
//  kolco24
//
//  Порт сетевой части `data/AdminAuthRepository.kt` — переходы admin-сессии (login/logout/
//  onUnauthorized). Чистое value-ядро (`AdminSession`, `isExpired`, `adminErrorMessage`) и сид
//  живут в `Core/Admin/` (Task 1–2); здесь — только то, что оперирует `PostResult` (тип `Net/`),
//  поэтому файл под `Data/` (прецедент stage-3 refresh-репозиториев: `Core/` не видит `Net/`).
//
//  Не `struct`-над-DAO, а `struct`-над-замыканиями: `apiLogin`/`apiLogout` бьют **cloud**-клиент
//  (админ-операции не ходят на LAN), `store` персистит сессию (Keychain-адаптер в проде), `holder`
//  синхронно отдаёт bearer подписному пайплайну. `import GRDB` не нужен (не касается БД).
//
//  Deviation от Android: сид (`seedSession`) переехал в `AdminSessionHolder.seed` (Task 2), чтобы
//  `AppEnvironment` посидировал сессию **до** создания клиентов; репозиторий только двигает сессию.
//

import Foundation

/// Переходы admin-сессии организатора поверх `PostResult`. Читает/пишет `store` (персист),
/// публикует состояние через `holder` (его же bearer читает подписной пайплайн `ApiClient`).
struct AdminAuthRepository {

    /// `POST /app/login/` на cloud-клиенте (email, password) → `PostResult<LoginResponse>`.
    let apiLogin: (String, String) async -> PostResult<LoginResponse>
    /// `POST /app/logout/` на cloud-клиенте (пустое тело) — best-effort, результат игнорируется.
    let apiLogout: () async -> PostResult<Void>
    let store: AdminTokenStore
    let holder: AdminSessionHolder

    init(
        apiLogin: @escaping (String, String) async -> PostResult<LoginResponse>,
        apiLogout: @escaping () async -> PostResult<Void>,
        store: AdminTokenStore,
        holder: AdminSessionHolder
    ) {
        self.apiLogin = apiLogin
        self.apiLogout = apiLogout
        self.store = store
        self.holder = holder
    }

    /// Попытка входа. На `.success` токен/email/expiry персистятся и сессия переходит в `.loggedIn`;
    /// неуспех **не трогает** сессию/стор. Статус маппится в `LoginOutcome` для формы через
    /// чистый `loginOutcome`.
    func login(email: String, password: String) async -> LoginOutcome {
        let result = await apiLogin(email, password)
        if case let .success(response) = result {
            store.write(
                StoredAdminSession(token: response.token, email: email, expiresAt: response.expiresAt)
            )
            holder.set(.loggedIn(email: email, token: response.token, expiresAt: response.expiresAt))
        }
        return loginOutcome(result)
    }

    /// Выход: `POST /app/logout/` best-effort (сервер отзывает токен), но локальный стор и сессия
    /// чистятся **всегда** — даже когда сеть упала оффлайн, чтобы локальная сессия не залипла
    /// «залогинена».
    func logout() async {
        _ = await apiLogout()
        store.clear()
        holder.set(.loggedOut)
    }

    /// Защищённый запрос вернул `401` (токен отозван/протух на сервере): чистит локальный стор и
    /// роняет сессию в `.loggedOut`, чтобы UI вернулся к форме входа.
    func onUnauthorized() {
        store.clear()
        holder.set(.loggedOut)
    }
}

/// Маппит login-`PostResult` в `LoginOutcome`: `401` → `.invalidCredentials` (неоднозначный
/// bad-credentials — сервер нарочно не различает), `429` → `.rateLimited`, `URLError` → `.offline`,
/// прочее → `.error`. Живёт в репозитории (не в `Core/`), т.к. видит `Net/`-тип `PostResult`.
func loginOutcome<T>(_ result: PostResult<T>) -> LoginOutcome {
    switch result {
    case .success:
        return .success
    case .unauthorized:
        return .invalidCredentials
    case .rateLimited:
        return .rateLimited
    case .offline:
        return .offline
    case .badRequest, .conflict, .forbidden, .error:
        return .error
    }
}
