//
//  AppEnvironmentInjectsTests.swift
//  kolco24Tests
//
//  Дефолты системных инжектов графа, добавленных под чек-лист готовности (`Core/Readiness`):
//  `locationAuthorization` (трёхзначный геостатус) и `isLowPowerMode` (энергосбережение).
//  Kotlin-источника нет — iOS-only. Прод-реализации device-only (`CLLocationManager`, `ProcessInfo`),
//  а проброс подменённых замыканий сквозь модель покрыт `MarksModelReadinessTests`, поэтому здесь
//  закреплено ровно одно, на что опираются остальные сюиты: НЕЙТРАЛЬНЫЕ дефолты `inMemory`
//  (иначе чужие тесты начали бы внезапно видеть пункты чек-листа).
//

import Foundation
import Testing
@testable import kolco24

@MainActor
struct AppEnvironmentInjectsTests {

    @Test func inMemoryDefaultsAreNeutral() throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle)

        #expect(env.locationAuthorization() == .granted)
        #expect(env.isLowPowerMode() == false)
        // Булев `hasLocationAccess` (TOCTOU-проверка `TrackRecorder`) новым инжектом не тронут.
        #expect(env.hasLocationAccess() == true)
    }
}
