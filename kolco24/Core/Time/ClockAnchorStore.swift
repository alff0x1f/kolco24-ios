//
//  ClockAnchorStore.swift
//  kolco24
//
//  Хранилище `ClockAnchor` (тёплый-старт-семя доверенного времени). Порт
//  `data/time/ClockAnchorStore.kt` 1:1: та же идиома (инъекция `load`/`save`-seam + продовый
//  `fromUserDefaults`-адаптер, синхронное чтение при конструировании).
//
//  **Атомарная запись (P1):** якорь хранится **одной delimited-строкой под одним ключом**, а не
//  четырьмя — kill процесса между записями иначе оставил бы смесь старых/новых полей, которая
//  парсится, но внутренне несогласованна. Один ключ → `write` = одна `save`.
//
//  Формат: `"serverEpochMs|anchorElapsedMs|capturedWallMs|bootCount?"` — пустой 4-й сегмент
//  кодирует `bootCount == nil`.
//
//  **Ловушка порта:** при `bootCount == nil` строка кончается на `|`. Kotlin `split('|')`
//  сохраняет хвостовой пустой сегмент (4 части); Swift `split(separator:)` по умолчанию его
//  отбрасывает. Поэтому парсим через `components(separatedBy: "|")` и требуем ровно 4 компоненты.
//

import Foundation

struct ClockAnchorStore {

    /// Ключ хранения (совпадает с Android `KEY_ANCHOR`).
    static let keyAnchor = "anchor"

    private let load: (String) -> String?
    private let save: (String, String?) -> Void

    init(load: @escaping (String) -> String?, save: @escaping (String, String?) -> Void) {
        self.load = load
        self.save = save
    }

    /// Читает персистнутый якорь, либо `nil`, если ключ отсутствует или строка битая (неверное
    /// число полей, либо нечисловой сегмент). Пустой 4-й сегмент → `bootCount = nil`.
    func read() -> ClockAnchor? {
        guard let raw = load(Self.keyAnchor) else { return nil }
        return Self.parse(raw)
    }

    /// Персистит `anchor` одной сериализованной строкой под одним ключом (одна `save`).
    func write(_ anchor: ClockAnchor) {
        save(Self.keyAnchor, Self.serialize(anchor))
    }

    /// Удаляет персистнутый якорь.
    func clear() {
        save(Self.keyAnchor, nil)
    }

    // MARK: - Чистые parse/format

    /// Разбирает delimited-строку в `ClockAnchor`, либо `nil` при любой некорректности.
    /// `components(separatedBy:)` сохраняет хвостовой пустой сегмент (как Kotlin `split('|')`).
    static func parse(_ raw: String) -> ClockAnchor? {
        let parts = raw.components(separatedBy: "|")
        guard parts.count == 4 else { return nil }
        guard let serverEpochMs = Int64(parts[0]),
              let anchorElapsedMs = Int64(parts[1]),
              let capturedWallMs = Int64(parts[2]) else { return nil }
        let bootCount: Int?
        if parts[3].isEmpty {
            bootCount = nil
        } else {
            guard let parsed = Int(parts[3]) else { return nil }
            bootCount = parsed
        }
        return ClockAnchor(
            serverEpochMs: serverEpochMs,
            anchorElapsedMs: anchorElapsedMs,
            capturedWallMs: capturedWallMs,
            bootCount: bootCount
        )
    }

    /// Сериализует `ClockAnchor` в delimited-строку (пустой 4-й сегмент при `bootCount == nil`).
    static func serialize(_ anchor: ClockAnchor) -> String {
        let boot = anchor.bootCount.map(String.init) ?? ""
        return "\(anchor.serverEpochMs)|\(anchor.anchorElapsedMs)|\(anchor.capturedWallMs)|\(boot)"
    }

    /// Продовый адаптер: подкладывает store под `UserDefaults.standard`. `nil`-значение удаляет ключ.
    static func fromUserDefaults(_ defaults: UserDefaults = .standard) -> ClockAnchorStore {
        ClockAnchorStore(
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
