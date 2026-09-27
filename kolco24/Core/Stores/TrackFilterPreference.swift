//
//  TrackFilterPreference.swift
//  kolco24
//
//  Персистнутый тумблер «Все точки». Порт `data/TrackFilterPreference.kt`. `true` — карта и GPX
//  показывают сырой трек (`trackLines(_, filter: false)`), иначе работает фильтр выбросов. Только
//  отображение — на сервер трек всегда уходит сырым.
//
//  В отличие от `ThemePreference` сам `@Observable` (аналог Kotlin `StateFlow`): его читают сразу
//  `MapModel`, `TeamModel` и `SettingsModel`, а пишут строка настроек и чип на карте — все видят одно
//  значение без моста через `AppModel`. Идиома `load`/`save`-seam + продовый `fromUserDefaults`.
//

import Foundation
import Observation

@Observable
final class TrackFilterPreference {

    /// Ключ хранения (совпадает с Android `KEY_SHOW_ALL_POINTS`).
    static let keyShowAllPoints = "track_show_all_points"

    @ObservationIgnored private let save: (Bool) -> Void

    /// Показывать ли все точки трека без фильтра (синхронное чтение при создании).
    private(set) var showAllPoints: Bool

    init(load: () -> Bool, save: @escaping (Bool) -> Void) {
        self.save = save
        self.showAllPoints = load()
    }

    func setShowAllPoints(_ value: Bool) {
        showAllPoints = value
        save(value)
    }

    /// Продовый адаптер: подкладывает store под `UserDefaults.standard`.
    static func fromUserDefaults(_ defaults: UserDefaults = .standard) -> TrackFilterPreference {
        TrackFilterPreference(
            load: { defaults.bool(forKey: keyShowAllPoints) },
            save: { defaults.set($0, forKey: keyShowAllPoints) }
        )
    }
}
