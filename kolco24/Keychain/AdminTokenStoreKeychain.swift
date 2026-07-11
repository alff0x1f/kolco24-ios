//
//  AdminTokenStoreKeychain.swift
//  kolco24
//
//  Продовый адаптер `AdminTokenStore` над Keychain — платформенный слой (прецедент
//  `Nfc/`/`Location/`/`Audio/`/`Photo/`). **Единственное** место `import Security` / `SecItem*`
//  в проекте (grep-инвариант этапа 10); чистое ядро `AdminTokenStore` живёт в `Core/Stores/`
//  и Foundation-only.
//
//  Один item `kSecClassGenericPassword`, service `kolco24.admin`; значение — JSON-`Data`
//  из `AdminTokenStore` (кодек — в ядре). `load` читает `kSecValueData`; `save(data)` делает
//  add-or-update; `save(nil)` удаляет item. Ошибки Keychain не бросаются — `load` → `nil`,
//  `save` — best-effort (та же контракт-безопасность, что и у остальных стор-адаптеров).
//

import Foundation
import Security

extension AdminTokenStore {

    /// Service-строка Keychain-item'а (аналог Android prefs-файла `kolco24.admin`).
    static let keychainService = "kolco24.admin"

    /// Продовый адаптер: подкладывает store под Keychain (`kSecClassGenericPassword`).
    static func fromKeychain(service: String = keychainService) -> AdminTokenStore {
        AdminTokenStore(
            load: { keychainLoad(service: service) },
            save: { keychainSave(service: service, data: $0) }
        )
    }

    // MARK: - Keychain primitives

    private static func baseQuery(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
    }

    private static func keychainLoad(service: String) -> Data? {
        var query = baseQuery(service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    private static func keychainSave(service: String, data: Data?) {
        guard let data else {
            SecItemDelete(baseQuery(service: service) as CFDictionary)
            return
        }
        // Токен админа не попадает в бэкапы и не восстанавливается на другое устройство:
        // ...WhenUnlockedThisDeviceOnly вместо дефолтного ...WhenUnlocked. Атрибут доступности
        // ставится и в add-, и в update-атрибутах (`SecItemUpdate` умеет менять `kSecAttrAccessible`),
        // чтобы любая перезапись нормализовала уже существующий item к ThisDeviceOnly — иначе item,
        // созданный до появления этого атрибута, сохранил бы старый backup-eligible класс. В
        // match-запросе load/update `kSecAttrAccessible` НЕ участвует.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(
            baseQuery(service: service) as CFDictionary,
            attributes as CFDictionary
        )
        if status == errSecItemNotFound {
            var addQuery = baseQuery(service: service)
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}
