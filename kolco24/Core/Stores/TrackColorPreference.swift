//
//  TrackColorPreference.swift
//  kolco24
//
//  Персистнутый тумблер «Цвет трека по скорости» (по умолчанию включён). Только отображение карты.
//  Идиома `TrackFilterPreference`: сам `@Observable`, `load`/`save`-seam + продовый `fromUserDefaults`.
//  Отдельный класс, а не второй флаг в `TrackFilterPreference`, — чтобы не трогать его init и тесты.
//

import Foundation
import Observation

@Observable
final class TrackColorPreference {

    static let keyColorBySpeed = "track_color_by_speed"

    @ObservationIgnored private let save: (Bool) -> Void

    /// Раскрашивать ли трек на карте по скорости (синхронное чтение при создании).
    private(set) var colorBySpeed: Bool

    init(load: () -> Bool, save: @escaping (Bool) -> Void) {
        self.save = save
        self.colorBySpeed = load()
    }

    func setColorBySpeed(_ value: Bool) {
        colorBySpeed = value
        save(value)
    }

    /// Продовый адаптер над `UserDefaults`. Отсутствующий ключ — `true` (`bool(forKey:)` дал бы `false`).
    static func fromUserDefaults(_ defaults: UserDefaults = .standard) -> TrackColorPreference {
        TrackColorPreference(
            load: { defaults.object(forKey: keyColorBySpeed) as? Bool ?? true },
            save: { defaults.set($0, forKey: keyColorBySpeed) }
        )
    }
}
