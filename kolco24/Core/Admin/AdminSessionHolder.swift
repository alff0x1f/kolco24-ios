//
//  AdminSessionHolder.swift
//  kolco24
//
//  Единый держатель текущей `AdminSession`. Идиома `LeaseHolder`: андроидный
//  `MutableStateFlow<AdminSession>` из `AdminAuthRepository` по-swiftски. Токен читается **синхронно**
//  подписным пайплайном `ApiClient` (`tokenProvider = { holder.token }`), поэтому значение под
//  `NSLock`, а не в `actor` (actor-hop недопустим на подписной точке). UI подписывается на `updates`.
//
//  Deviation от Android: сид-логика (`seedSession`) переезжает из репозитория **в holder** (`seed`),
//  чтобы `AppEnvironment` посидировал сессию **до** создания клиентов/репозитория (оба клиента берут
//  `tokenProvider` из holder). Репозиторий (Task 4) двигает сессию через `set(_:)` на login/logout;
//  запись/очистка стора — его забота, holder только держит и публикует (без write-through).
//
//  Поток `updates` следует `TrustedClock.statusUpdates`/`LeaseHolder`: `AsyncStream` с
//  `.bufferingNewest(1)`, ручной дедуп равных, seed текущим значением (первый кадр уже в буфере).
//

import Foundation

final class AdminSessionHolder: @unchecked Sendable {

    private let lock = NSLock()
    private var _session: AdminSession

    /// Поток обновлений сессии (замена `StateFlow`; равные значения дедупятся). Потребитель —
    /// `AdminHomeView`, ветвящийся между формой входа и меню.
    nonisolated let updates: AsyncStream<AdminSession>
    private let continuation: AsyncStream<AdminSession>.Continuation

    /// - Parameter initial: засеянное значение (обычно `AdminSessionHolder.seed(...)`); сразу кладётся
    ///   в буфер стрима.
    init(initial: AdminSession) {
        self._session = initial

        var cont: AsyncStream<AdminSession>.Continuation!
        self.updates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        self.continuation = cont
        cont.yield(initial)
    }

    /// Текущая сессия (синхронное чтение под замком).
    var session: AdminSession {
        lock.lock()
        defer { lock.unlock() }
        return _session
    }

    /// Синхронный bearer-токен для подписного пайплайна (без async, без I/O): токен при [loggedIn],
    /// иначе `nil`.
    var token: String? {
        lock.lock()
        defer { lock.unlock() }
        if case let .loggedIn(_, token, _) = _session { return token }
        return nil
    }

    /// Устанавливает сессию: дедуп равных (полный no-op), иначе публикация в стрим.
    func set(_ session: AdminSession) {
        lock.lock()
        guard session != _session else {
            lock.unlock()
            return
        }
        _session = session
        lock.unlock()

        continuation.yield(session)
    }

    /// Считает начальную сессию из [store] на момент [nowUtcIso]: сохранённая, но протухшая →
    /// `store.clear()` + `.loggedOut`; живая → `.loggedIn`; пустой стор → `.loggedOut`. Порт
    /// `AdminAuthRepository.seedSession`, но как чистая фабрика в holder-слое (deviation, см. заголовок).
    static func seed(store: AdminTokenStore, nowUtcIso: String) -> AdminSession {
        guard let stored = store.read() else { return .loggedOut }
        if isExpired(expiresAt: stored.expiresAt, nowUtcIso: nowUtcIso) {
            store.clear()
            return .loggedOut
        }
        return .loggedIn(email: stored.email, token: stored.token, expiresAt: stored.expiresAt)
    }
}
