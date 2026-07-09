//
//  LiveServerSmokeTests.swift
//  kolco24Tests
//
//  Единственная проверка прод-`URLSession`-транспорта против ЖИВОГО сервера — платформенный код без
//  прямого Kotlin-зеркала (Android покрывает это MockWebServer'ом; здесь фейк-транспорт из
//  `ApiClientTests` уже отвечает за пайплайн, а сеть нужна ровно для того, чтобы убедиться, что
//  подпись принимается настоящим сервером). Поэтому suite помечен как smoke, а не «Зеркало …».
//
//  Гейтится env `LIVE_API_SMOKE`: без переменной весь suite пропускается (`.enabled(if:)`), так что
//  локальный/CI-прогон без сети остаётся зелёным. Запуск руками:
//    LIVE_API_SMOKE=1 xcodebuild test … -only-testing:kolco24Tests/LiveServerSmokeTests
//

import Foundation
import Testing
@testable import kolco24

// MARK: - Smoke (gated, без Kotlin-зеркала)

@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIVE_API_SMOKE"] != nil))
struct LiveServerSmokeTests {

    /// Подписанный `GET /app/races/` через настоящий `URLSessionTransport` и реальные `Secrets` →
    /// ожидаем `.success` (сервер принял подпись: 200, не 403). Клиент собирается фабрикой ровно как в
    /// проде (cloud, `TrustedClock.makeDefault()`, install id из `UserDefaults`).
    @Test func signedRacesFetchIsAccepted() async {
        let (cloud, _, _) = ApiClients.makeDefaultPair()
        let result = await cloud.fetchRaces(etag: nil)
        switch result {
        case .success:
            break
        case .notModified, .forbidden, .error:
            Issue.record("expected .success from live server, got \(result)")
        }
    }
}
