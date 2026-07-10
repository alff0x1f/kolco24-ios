//
//  ThemePreference.swift
//  kolco24
//
//  Персистнутая настройка темы приложения. Порт `data/ThemePreference.kt` + `ui/theme/ThemeMode.kt`.
//  Идиома `RaceLeaseStore`/`ClockAnchorStore`: инъекция `load`/`save`-seam + продовый
//  `fromUserDefaults`-адаптер, синхронное чтение текущего значения при конструировании (первый
//  кадр уже отражает сохранённый режим — без вспышки светлой темы на холодном старте с DARK).
//
//  Rawvalue enum'а — **uppercase** ("SYSTEM"/"LIGHT"/"DARK"), байт-в-байт с Kotlin `.name`, чтобы
//  формат персиста был совместим и зеркальные ассерты строк остались дословными.
//

import Foundation

/// Пользовательский режим темы (зеркало Kotlin `ThemeMode`).
///
/// `system` следует OS dark-mode (дефолт); `light`/`dark` его переопределяют. Маппинг в
/// `ColorScheme` живёт в UI-слое — `Core/` остаётся свободен от SwiftUI/UIKit.
enum ThemeMode: String, CaseIterable {
    case system = "SYSTEM"
    case light = "LIGHT"
    case dark = "DARK"
}

/// Разбирает персистнутое имя в `ThemeMode`; `nil`/неизвестное → `.system` (forward-compatible).
func parseThemeMode(_ raw: String?) -> ThemeMode {
    guard let raw, let mode = ThemeMode(rawValue: raw) else { return .system }
    return mode
}

/// Персистнутая настройка темы. Значение читается **синхронно** при конструировании (через `load`),
/// `setMode` пишет `rawValue` через `save`-seam. Store инъецируется чистыми `load`/`save`-замыканиями,
/// `fromUserDefaults` — тонкий продовый адаптер (зеркало `ThemePreference.fromSharedPreferences`).
final class ThemePreference {

    /// Ключ хранения (совпадает с Android `KEY_THEME_MODE`).
    static let keyThemeMode = "theme_mode"

    private let save: (String) -> Void

    /// Текущий режим темы (синхронное чтение при создании).
    private(set) var mode: ThemeMode

    init(load: () -> String?, save: @escaping (String) -> Void) {
        self.save = save
        self.mode = parseThemeMode(load())
    }

    /// Устанавливает режим и персистит его `rawValue`.
    func setMode(_ m: ThemeMode) {
        mode = m
        save(m.rawValue)
    }

    /// Продовый адаптер: подкладывает store под `UserDefaults.standard`.
    static func fromUserDefaults(_ defaults: UserDefaults = .standard) -> ThemePreference {
        ThemePreference(
            load: { defaults.string(forKey: keyThemeMode) },
            save: { defaults.set($0, forKey: keyThemeMode) }
        )
    }
}
