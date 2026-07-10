//
//  RaceLeaseStore.swift
//  kolco24
//
//  Хранилище текущего `RaceLease` (LAN-пин). Порт `data/lease/RaceLeaseStore.kt` 1:1: та же
//  идиома, что у `ClockAnchorStore` (инъекция `load`/`save`-seam + продовый
//  `fromUserDefaults`-адаптер, синхронное чтение при конструировании).
//
//  **Атомарная запись:** lease хранится **одной delimited-строкой под одним ключом** —
//  `"raceId|expiresAtMs"` — так что `write` = одна `save`; персистнутый lease всегда целый
//  либо отсутствует. Пинится только одна гонка за раз.
//

import Foundation

struct RaceLeaseStore {

    /// Ключ хранения (совпадает с Android `KEY_LEASE`).
    static let keyLease = "race_lease"

    private let load: (String) -> String?
    private let save: (String, String?) -> Void

    init(load: @escaping (String) -> String?, save: @escaping (String, String?) -> Void) {
        self.load = load
        self.save = save
    }

    /// Читает персистнутый lease, либо `nil`, если ключ отсутствует или строка битая (неверное
    /// число компонент, либо нечисловой сегмент).
    func read() -> RaceLease? {
        guard let raw = load(Self.keyLease) else { return nil }
        return Self.parse(raw)
    }

    /// Персистит `lease` одной сериализованной строкой под одним ключом (одна `save`).
    func write(_ lease: RaceLease) {
        save(Self.keyLease, Self.serialize(lease))
    }

    /// Удаляет персистнутый lease.
    func clear() {
        save(Self.keyLease, nil)
    }

    // MARK: - Чистые parse/format

    /// Разбирает delimited-строку в `RaceLease`, либо `nil` при любой некорректности (не ровно 2
    /// компоненты через `components(separatedBy:)`, либо нечисловой сегмент).
    static func parse(_ raw: String) -> RaceLease? {
        let parts = raw.components(separatedBy: "|")
        guard parts.count == 2 else { return nil }
        guard let raceId = Int(parts[0]),
              let expiresAtMs = Int64(parts[1]) else { return nil }
        return RaceLease(raceId: raceId, expiresAtMs: expiresAtMs)
    }

    /// Сериализует `RaceLease` в delimited-строку `"raceId|expiresAtMs"`.
    static func serialize(_ lease: RaceLease) -> String {
        "\(lease.raceId)|\(lease.expiresAtMs)"
    }

    /// Продовый адаптер: подкладывает store под `UserDefaults.standard`. `nil`-значение удаляет ключ.
    static func fromUserDefaults(_ defaults: UserDefaults = .standard) -> RaceLeaseStore {
        RaceLeaseStore(
            load: { defaults.string(forKey: $0) },
            save: { key, value in
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        )
    }
}
