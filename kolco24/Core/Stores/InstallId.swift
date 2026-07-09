//
//  InstallId.swift
//  kolco24
//
//  Стабильный per-install идентификатор, отправляемый заголовком `X-Install-Id` (см. docs/API.md)
//  и пишущийся в `judge_scans.sourceInstallId`. API ограничивает его 64 символами; UUID-строка —
//  36, так что всегда влезает.
//
//  Порт `data/InstallId.kt` 1:1: read-or-generate — чистая функция над инъецированным key-value
//  seam'ом (тестируется без UserDefaults), `fromUserDefaults` — тонкий продовый адаптер.
//  Идиома совпадает с `TrustedClock`/`ClockAnchorStore` (инъекция `load`/`save`-замыканий).
//

import Foundation

enum InstallId {

    /// Ключ хранения (совпадает с Android `KEY_INSTALL_ID`).
    static let keyInstallId = "install_id"

    /// Возвращает существующий id из `load`, либо генерирует новый, персистит его через `save`
    /// и возвращает.
    static func getOrCreate(load: () -> String?, save: (String) -> Void) -> String {
        if let existing = load() {
            return existing
        }
        let generated = UUID().uuidString
        save(generated)
        return generated
    }

    /// Продовый адаптер: подкладывает `getOrCreate` под `UserDefaults.standard`
    /// (без отдельного suite — см. Technical Details этапа 2).
    static func fromUserDefaults(_ defaults: UserDefaults = .standard) -> String {
        getOrCreate(
            load: { defaults.string(forKey: keyInstallId) },
            save: { defaults.set($0, forKey: keyInstallId) }
        )
    }
}
