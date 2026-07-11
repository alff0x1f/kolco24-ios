//
//  AdminTokenStore.swift
//  kolco24
//
//  Хранилище admin-bearer-сессии. Порт `data/AdminTokenStore.kt`, но с **платформенной адаптацией**:
//  Android держит три отдельных ключа в SharedPreferences-файле `kolco24.admin`; iOS — **один
//  JSON-item в Keychain** (`{token, email, expiresAt}`), так что сессия персистится атомарно —
//  целиком либо отсутствует (прецедент `RaceLeaseStore` с одной delimited-строкой).
//
//  Идиома совпадает с `ClockAnchorStore`/`RaceLeaseStore`: чистое ядро на инъецированных
//  `load: () -> Data?` / `save: (Data?) -> Void`-замыканиях (тестируется без Keychain), а
//  продовый адаптер `fromKeychain()` живёт в платформенной папке `Keychain/` — единственном месте
//  `import Security`. `Core/Stores/` остаётся Foundation-only (grep-инвариант этапа 9).
//

import Foundation

/// Персистнутые поля admin-сессии: opaque 30-дневный bearer [token], [email] входа и сырая
/// ISO-строка [expiresAt] от сервера (UTC, `Z`-суффикс). Кодируется в один JSON-item.
struct StoredAdminSession: Equatable, Codable {
    let token: String
    let email: String
    let expiresAt: String
}

struct AdminTokenStore {

    private let load: () -> Data?
    private let save: (Data?) -> Void

    init(load: @escaping () -> Data?, save: @escaping (Data?) -> Void) {
        self.load = load
        self.save = save
    }

    /// Читает сохранённую сессию, либо `nil`, если item отсутствует, JSON битый, или **любое**
    /// из трёх полей пустое (неполная сессия недопустима — паритет с Android «любой ключ отсутствует
    /// → null»).
    func read() -> StoredAdminSession? {
        guard let data = load() else { return nil }
        guard let session = try? JSONDecoder().decode(StoredAdminSession.self, from: data) else {
            return nil
        }
        guard !session.token.isEmpty,
              !session.email.isEmpty,
              !session.expiresAt.isEmpty else { return nil }
        return session
    }

    /// Персистит сессию одним JSON-item (одна `save`, целиком заменяя предыдущий item).
    func write(_ session: StoredAdminSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        save(data)
    }

    /// Удаляет сохранённую сессию.
    func clear() {
        save(nil)
    }
}
