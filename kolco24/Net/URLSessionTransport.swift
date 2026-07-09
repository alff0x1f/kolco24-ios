//
//  URLSessionTransport.swift
//  kolco24
//
//  Прод-транспорт + фабрика клиентов — порт `ApiClient.defaultOkHttpClient` + `AppContainer.kt`
//  (двухклиентный вайринг cloud/LAN).
//
//  Адаптация под платформу (требование этапа: НЕ 1в1 из Kotlin). У URLSession нет OkHttp-клиента с
//  цепочкой интерсепторов — подпись/время/403-retry уже сложены в пайплайн `ApiClient`. Здесь остаётся
//  чистый транспорт: обёртка над `URLSession` эфемерной конфигурации **без кэша** (аналог «no response
//  `Cache` configured» из Kotlin — каждый `Date`-заголовок, включая на `304`, живой сетевой) и
//  настраиваемым таймаутом (cloud 10 с, LAN 3 с — быстрый офлайн-фейл вне Wi-Fi).
//
//  `Net/` без `import GRDB`/`UIKit`/`SwiftUI` (grep-инвариант этапа 3). Импортируем только Foundation.
//  Вайринг в приложение (аналог `AppContainer` целиком) — этап 4; этап 3 сдаёт транспорт + фабрику.
//

import Foundation

/// Транспорт-seam для `ApiClient` поверх `URLSession`. Эфемерная сессия без кэша (`Date` всегда
/// живой) с единым таймаутом на запрос. Даётся `ApiClient.transport` как bound-метод `send` —
/// замыкание удерживает экземпляр, поэтому сессия живёт всё время жизни клиента.
final class URLSessionTransport {

    private let session: URLSession

    /// - Parameter timeoutSeconds: единый таймаут запроса (аналог connect/read из OkHttp — cloud 10 с,
    ///   LAN 3 с). Мапится на `timeoutIntervalForRequest` **и** `timeoutIntervalForResource`, чтобы
    ///   висящий ответ на LAN тоже падал быстро, а не по дефолтным 7 суткам.
    init(timeoutSeconds: TimeInterval) {
        let config = URLSessionConfiguration.ephemeral
        // Без кэша: заголовок `Date` (в т.ч. на 304) обязан быть живым сетевым значением — на нём
        // якорится `TrustedClock`. `.reloadIgnoringLocalCacheData` — защита в глубину поверх nil-кэша.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds
        self.session = URLSession(configuration: config)
    }

    /// Один проход: шлёт `request`, возвращает `(Data, HTTPURLResponse)`. Не-HTTP-ответ (не бывает для
    /// http/https, но `URLResponse` формально шире) → `URLError(.badServerResponse)` — сворачивается
    /// вызывателем в `.error(nil)`/`.offline`, как транспортный обрыв.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// Фабрика двух `ApiClient`-экземпляров (по образцу `AppContainer.kt`): cloud (HTTPS, 10 с,
/// перезаякоривает `TrustedClock` по каждому ответу) и LAN (cleartext локального сервера, 3 с, **без**
/// `onServerTime` — LAN-хост никогда не якорит доверенное время). Оба подписываются одинаково (тот же
/// key id / secret / 6 заголовков, `nowSeconds` = один и тот же `TrustedClock.signingSeconds`).
enum ApiClients {

    /// `X-App-Version` — `CFBundleShortVersionString` из бандла (аналог `BuildConfig.VERSION_NAME`).
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Cloud-клиент: `Secrets.apiBaseURL`, таймауты 10 с, `onServerTime` → `trustedClock` (захватывает
    /// `wallNow`/`bootNow` из `SystemClockProviders` — сэмплер их не даёт).
    static func makeCloud(
        trustedClock: TrustedClock,
        installId: String,
        tokenProvider: @escaping () -> String? = { nil }
    ) -> ApiClient {
        let transport = URLSessionTransport(timeoutSeconds: 10)
        return ApiClient(
            baseURL: Secrets.apiBaseURL,
            keyId: Secrets.appKeyId,
            secret: Secrets.appSecret,
            installId: installId,
            appVersion: appVersion,
            nowSeconds: { await trustedClock.signingSeconds() },
            elapsedNowMs: SystemClockProviders.elapsedRealtimeMs,
            // Вайринг-замыкание фабрики: `ServerTimeSample` (serverEpoch + midpoint-anchor) от сэмплера
            // + свежие `wallNow`/`bootNow` из системных провайдеров → `TrustedClock.onServerTime`.
            onServerTime: { sample in
                await trustedClock.onServerTime(
                    serverMs: sample.serverEpochMs,
                    anchorElapsed: sample.anchorElapsedMs,
                    wallNow: SystemClockProviders.wallClockMs(),
                    bootNow: SystemClockProviders.bootCount()
                )
            },
            tokenProvider: tokenProvider,
            transport: transport.send
        )
    }

    /// LAN-клиент: `Secrets.localAPIBaseURL`, таймауты 3 с (быстрый офлайн-фейл вне Wi-Fi),
    /// `onServerTime = nil` (второй хост — доверенное время с него не якорится). Подпись — тот же
    /// `trustedClock.signingSeconds`, что и у cloud.
    static func makeLocal(
        trustedClock: TrustedClock,
        installId: String,
        tokenProvider: @escaping () -> String? = { nil }
    ) -> ApiClient {
        let transport = URLSessionTransport(timeoutSeconds: 3)
        return ApiClient(
            baseURL: Secrets.localAPIBaseURL,
            keyId: Secrets.appKeyId,
            secret: Secrets.appSecret,
            installId: installId,
            appVersion: appVersion,
            nowSeconds: { await trustedClock.signingSeconds() },
            elapsedNowMs: SystemClockProviders.elapsedRealtimeMs,
            onServerTime: nil,
            tokenProvider: tokenProvider,
            transport: transport.send
        )
    }

    /// Пара клиентов над **общим** `TrustedClock.makeDefault()` + `InstallId.fromUserDefaults()`
    /// (только cloud якорит время). Полный вайринг в приложение (`AppContainer`-аналог) — этап 4; это
    /// удобный сборщик по умолчанию (и точка входа live-smoke).
    static func makeDefaultPair(
        tokenProvider: @escaping () -> String? = { nil }
    ) -> (cloud: ApiClient, local: ApiClient, clock: TrustedClock) {
        let clock = TrustedClock.makeDefault()
        let installId = InstallId.fromUserDefaults()
        return (
            cloud: makeCloud(trustedClock: clock, installId: installId, tokenProvider: tokenProvider),
            local: makeLocal(trustedClock: clock, installId: installId, tokenProvider: tokenProvider),
            clock: clock
        )
    }
}
