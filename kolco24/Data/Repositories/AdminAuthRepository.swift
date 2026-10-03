//
//  AdminAuthRepository.swift
//  kolco24
//
//  Порт сетевой части `data/AdminAuthRepository.kt` — переходы admin-сессии (login/logout/
//  onUnauthorized). Чистое value-ядро (`AdminSession`, `isExpired`, `adminErrorMessage`) и сид
//  живут в `Core/Admin/` (Task 1–2); здесь — только то, что оперирует `PostResult` (тип `Net/`),
//  поэтому файл под `Data/` (прецедент stage-3 refresh-репозиториев: `Core/` не видит `Net/`).
//
//  Не `struct`-над-DAO, а `struct`-над-замыканиями. Экземпляров два — cloud и LAN (LAN-сервер гонки
//  выдаёт свои токены через свой `/app/login/`): `apiLogin`/`apiLogout` бьют свой клиент, `store`
//  персистит сессию (свой Keychain-item), `holder` синхронно отдаёт bearer подписному пайплайну
//  **своего** клиента. `import GRDB` не нужен (не касается БД).
//
//  Deviation от Android: сид (`seedSession`) переехал в `AdminSessionHolder.seed` (Task 2), чтобы
//  `AppEnvironment` посидировал сессию **до** создания клиентов; репозиторий только двигает сессию.
//

import Foundation

/// Переходы admin-сессии организатора поверх `PostResult`. Читает/пишет `store` (персист),
/// публикует состояние через `holder` (его же bearer читает подписной пайплайн `ApiClient`).
struct AdminAuthRepository {

    /// `POST /app/login/` на клиенте этого сервера (email, password) → `PostResult<LoginResponse>`.
    let apiLogin: (String, String) async -> PostResult<LoginResponse>
    /// `POST /app/logout/` на клиенте этого сервера (пустое тело) — best-effort, результат игнорируется.
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

    /// Попытка входа. На `.success` токен/email/expiry/adminRaceIds персистятся и сессия переходит в `.loggedIn`;
    /// неуспех **не трогает** сессию/стор. Статус маппится в `LoginOutcome` для формы через
    /// чистый `loginOutcome`. Успех, пришедший после `logout()`, начатого во время запроса,
    /// отбрасывается и возвращается как `.error`.
    func login(email: String, password: String) async -> LoginOutcome {
        let startedAt = holder.loginGeneration
        let result = await apiLogin(email, password)
        if case let .success(response) = result {
            let store = store
            let committed = holder.commitLogin(
                .loggedIn(
                    email: email,
                    token: response.token,
                    expiresAt: response.expiresAt,
                    adminRaceIds: response.adminRaceIds
                ),
                generation: startedAt
            ) {
                store.write(
                    StoredAdminSession(
                        token: response.token,
                        email: email,
                        expiresAt: response.expiresAt,
                        adminRaceIds: response.adminRaceIds
                    )
                )
            }
            if !committed { return .error }
        }
        return loginOutcome(result)
    }

    /// Выход: `POST /app/logout/` best-effort (сервер отзывает токен), но локальный стор и сессия
    /// чистятся **всегда** — даже когда сеть упала оффлайн, чтобы локальная сессия не залипла
    /// «залогинена». Также отменяет login'ы в полёте; без сессии только это (без запроса).
    func logout() async {
        holder.invalidateLogins()
        if holder.session == .loggedOut { return }
        _ = await apiLogout()
        holder.set(.loggedOut) { store.clear() }
    }

    /// Защищённый запрос вернул `401` (токен отозван/протух на сервере): чистит локальный стор и
    /// роняет сессию в `.loggedOut`, чтобы UI вернулся к форме входа.
    func onUnauthorized() {
        holder.set(.loggedOut) { store.clear() }
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
