//
//  RepositoryTestSupport.swift
//  kolco24Tests
//
//  Общие помощники репозиторных тестов этапа 3 (задачи 6–7). `TraceLog` — потокобезопасный журнал
//  трассируемого SQL (`Database.trace`), Swift-аналог callLog'а из фейковых DAO в Kotlin;
//  `CallCounter` — потокобезопасный счётчик для `isRacePinned`-seam'ов, моделирующих смену источника
//  «в полёте» (`checks++ > 0` / `checks++ == 0` из Kotlin); `firstValue` берёт первое значение
//  `AsyncValueObservation` (аналог `flow.first()`).
//
//  `RaceRepositoryTests` использует этот общий `TraceLog`, а собственным держит только file-private
//  helper `callSequence` — он не конфликтует с этими internal-версиями.
//

import Foundation
import GRDB

/// Потокобезопасный журнал трассируемого SQL (`Database.trace` дёргается на очереди соединения).
final class TraceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(line)
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        storage.removeAll()
    }
}

/// Потокобезопасный монотонный счётчик вызовов — Swift-аналог `var checks = 0; checks++` из Kotlin.
/// `next()` возвращает текущее значение и инкрементирует (первый вызов → `0`).
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        let v = n
        n += 1
        return v
    }

    /// Текущее число вызовов `next()` (без инкремента).
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return n
    }
}

/// Первое значение `AsyncValueObservation` — аналог `Flow.first()` из Kotlin-тестов.
func firstValue<T>(_ observation: AsyncValueObservation<T>) async throws -> T {
    for try await value in observation {
        return value
    }
    throw CancellationError()
}
