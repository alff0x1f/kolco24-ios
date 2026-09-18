//
//  AppEnvironmentInjectsTests.swift
//  kolco24Tests
//
//  Тесты системных инжектов графа, добавленных под чек-лист готовности (`Core/Readiness`):
//  `locationAuthorization` (трёхзначный геостатус) и `isLowPowerMode` (режим энергосбережения).
//  Kotlin-источника нет — iOS-only. Прод-реализации device-only (`CLLocationManager`, `ProcessInfo`),
//  поэтому здесь проверяется ровно шов: дефолты `inMemory` и проброс подменённых замыканий.
//

import Foundation
import Testing
@testable import kolco24

@MainActor
struct AppEnvironmentInjectsTests {

    private func env(
        locationAuthorization: @escaping @Sendable () -> LocationAuthorization = { .granted },
        isLowPowerMode: @escaping @Sendable () -> Bool = { false }
    ) throws -> AppEnvironment {
        try AppEnvironment.inMemory(
            transport: FakeTransport().handle,
            locationAuthorization: locationAuthorization,
            isLowPowerMode: isLowPowerMode
        )
    }

    /// Дефолты тестового графа: «разрешение выдано», «энергосбережение выключено» — нейтральное
    /// состояние, при котором существующие сюиты не начинают видеть пункты чек-листа.
    @Test func inMemoryDefaults() throws {
        let e = try env()
        #expect(e.locationAuthorization() == .granted)
        #expect(e.isLowPowerMode() == false)
    }

    /// Подменённые замыкания доходят до графа как есть (опрос, а не кеш: значение читается на каждом вызове).
    @Test func injectedClosuresAreForwarded() throws {
        let e = try env(locationAuthorization: { .denied }, isLowPowerMode: { true })
        #expect(e.locationAuthorization() == .denied)
        #expect(e.isLowPowerMode() == true)
    }

    /// `.notDetermined` — отдельное от `.denied` значение (ради него инжект и заводился: булев
    /// `hasLocationAccess` схлопывает оба в `false`). Сам `hasLocationAccess` остаётся на месте.
    @Test func notDeterminedIsDistinctFromDenied() throws {
        let e = try env(locationAuthorization: { .notDetermined })
        #expect(e.locationAuthorization() == .notDetermined)
        #expect(e.hasLocationAccess() == true) // дефолт inMemory не тронут новым инжектом
    }

    /// Опрос, а не снимок: меняющееся замыкание видно графу без пересборки.
    @Test func lowPowerModeIsPolled() throws {
        let box = MutableFlag()
        let e = try env(isLowPowerMode: { box.value })
        #expect(e.isLowPowerMode() == false)
        box.value = true
        #expect(e.isLowPowerMode() == true)
    }
}

/// Потокобезопасный флаг для `@Sendable`-замыкания.
private final class MutableFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}
