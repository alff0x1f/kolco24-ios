//
//  ScanLiveness.swift
//  kolco24
//
//  Потокобезопасный флаг «окно/лист жив» для решения `NfcChipScanner.shouldRestart` (§60-с молчаливый
//  рестарт сессии). Сканер читает его на СВОЕЙ делегатной очереди CoreNFC (не main), а хост-модель
//  (@MainActor) обновляет по мере открытия/закрытия оверлея и bind-листа. Это заменяет прямое
//  синхронное чтение @MainActor-состояния (`closeRequested` / `bindMember`) с делегатной очереди —
//  межпотоковую гонку данных.
//
//  Живёт под `Core/Scan/` (рядом с `ChipScanning`): CoreNFC не импортирует, поэтому App-слой держит на
//  него ссылку не нарушая grep-инвариант (модуль NFC подключают только файлы под `Nfc/`).
//

import Foundation

/// Потокобезопасная булева ячейка: пишется на MainActor, читается с делегатной NFC-очереди под `NSLock`.
final class ScanLiveness: @unchecked Sendable {
    private let lock = NSLock()
    private var alive: Bool

    init(alive: Bool = false) {
        self.alive = alive
    }

    /// Жив ли оверлей/лист (читается сканером на делегатной очереди).
    var isAlive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return alive
    }

    /// Обновить состояние (пишет хост на MainActor).
    func set(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        alive = value
    }
}
