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
//  Deviation от `LeaseHolder`: здесь **мульти-консумер** реестр континуэйшнов, а не единственный
//  стрим. `updates` — вычисляемое свойство: каждое обращение чеканит **свежий** `AsyncStream`,
//  засеянный текущим значением и зарегистрированный в реестре под замком. Причина — потребитель
//  (`AdminHomeView` во `fullScreenCover`) итерирует стрим из `.task`, который отменяется при закрытии
//  ковера; одиночный `let`-стрим после этого мёртв для всех будущих подписчиков (второе открытие ковера
//  в рамках одного запуска перестаёт реагировать на login/logout/401). Свежий стрим на подписку это
//  чинит; `onTermination` снимает свою континуэйшн из реестра (берёт `NSLock` — колбэк приходит на
//  произвольном executor, без обратных вызовов в async-контекст).
//

import Foundation

final class AdminSessionHolder: @unchecked Sendable {

    private let lock = NSLock()
    private var _session: AdminSession

    /// Реестр активных континуэйшнов подписчиков (мульти-консумер fan-out). Ключ — монотонный id,
    /// чтобы `onTermination` мог снять именно свою запись.
    private var continuations: [Int: AsyncStream<AdminSession>.Continuation] = [:]
    private var nextContinuationId = 0

    /// - Parameter initial: засеянное значение (обычно `AdminSessionHolder.seed(...)`).
    init(initial: AdminSession) {
        self._session = initial
    }

    /// Поток обновлений сессии (замена `StateFlow`; равные значения дедупятся). Потребитель —
    /// `AdminHomeView`, ветвящийся между формой входа и меню. **Вычисляемое** свойство: каждое обращение
    /// чеканит свежий стрим, засеянный текущим значением, — так повторная подписка (второе открытие
    /// ковера) снова живая.
    nonisolated var updates: AsyncStream<AdminSession> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont in
            lock.lock()
            let id = nextContinuationId
            nextContinuationId += 1
            continuations[id] = cont
            let seed = _session
            // Сид отдаётся ПОД замком, до его снятия: конкурентный `set(_:)` не может вклиниться
            // между регистрацией континуэйшн и yield'ом сида и доставить более новую сессию раньше
            // (иначе в `.bufferingNewest(1)`-буфере осталась бы протухшая сессия). Безопасно: yield в
            // буферизующий `AsyncStream` не входит синхронно в `onTermination`, а `onTermination`
            // берёт тот же замок только позже (на finish/cancel), не внутри yield — самоблокировки нет.
            cont.yield(seed)
            lock.unlock()

            cont.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
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

    /// Устанавливает сессию: дедуп равных (полный no-op), иначе публикация во все активные стримы.
    func set(_ session: AdminSession) {
        lock.lock()
        guard session != _session else {
            lock.unlock()
            return
        }
        _session = session
        let targets = Array(continuations.values)
        lock.unlock()

        for cont in targets {
            cont.yield(session)
        }
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
