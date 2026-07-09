//
//  ServerTimeSampler.swift
//  kolco24
//
//  Порт `data/api/ServerTimeInterceptor.kt` — но **не** OkHttp-интерсептор: чистая функция
//  разбора `Date`-заголовка ответа + RTT-правила. `ApiClient` замеряет монотонный elapsed до и
//  после транспорта и зовёт `sample(...)`; принятый результат уходит в `TrustedClock.onServerTime`.
//
//  Отличие от Kotlin по требованию платформы: сетевой-gate (`networkResponse != null`) здесь
//  беспредметен — прод-транспорт эфемерный без кэша (`Date` всегда живой, зафиксировано конфигом
//  URLSessionTransport), поэтому в сэмплер он не входит. `wallNow`/`bootNow`, нужные
//  `TrustedClock.onServerTime`, тоже не дело сэмплера — их захватывает вайринг-замыкание фабрики
//  из `SystemClockProviders`. Out-of-order ответы разруливает сам `TrustedClock` (отбрасывает
//  монотонную регрессию), не сэмплер.
//

import Foundation

/// Одно принятое серверное измерение времени: серверный epoch (мс) и монотонный `elapsed`-якорь
/// (мс), к которому оно привязано (середина RTT). Соответствует аргументам
/// `TrustedClock.onServerTime(serverMs:anchorElapsed:…)`.
struct ServerTimeSample: Equatable {
    let serverEpochMs: Int64
    let anchorElapsedMs: Int64
}

enum ServerTimeSampler {

    /// Верхняя граница приемлемого round-trip (мс). Порт дефолта `maxRttMs = 10_000` из Kotlin:
    /// негативный RTT — таймингова аномалия, сверхдлинный делает midpoint-коррекцию слишком грубой.
    static let maxRttMs: Int64 = 10_000

    /// Разбор `Date`-заголовка + RTT-правила. Возвращает `nil` (no-op) при отсутствующем/битом
    /// `Date`, отрицательном RTT или RTT > `maxRttMs`.
    ///
    /// - Parameters:
    ///   - dateHeader: значение HTTP-заголовка `Date` (RFC 1123), либо `nil` если его нет.
    ///   - requestElapsedMs: чтение монотонного `elapsed` **до** транспорта.
    ///   - responseElapsedMs: чтение монотонного `elapsed` **после** транспорта.
    ///   - maxRttMs: верхняя граница RTT (для тестов; прод берёт дефолт).
    static func sample(
        dateHeader: String?,
        requestElapsedMs: Int64,
        responseElapsedMs: Int64,
        maxRttMs: Int64 = ServerTimeSampler.maxRttMs
    ) -> ServerTimeSample? {
        let rtt = responseElapsedMs - requestElapsedMs
        // RTT в диапазоне (негативный = аномалия, сверхлимитный = слишком грубо).
        guard rtt >= 0, rtt <= maxRttMs else { return nil }
        guard let serverEpochMs = parseHttpDate(dateHeader) else { return nil }
        // overflow-safe midpoint — `before + rtt/2`, не `(before + after)/2` (порт из Kotlin).
        let anchorElapsedMs = requestElapsedMs + rtt / 2
        return ServerTimeSample(serverEpochMs: serverEpochMs, anchorElapsedMs: anchorElapsedMs)
    }

    /// Разбор HTTP-`Date` (RFC 1123, GMT) в epoch-миллисекунды; `nil` при отсутствии/битом формате
    /// (аналог `Headers.getDate("Date")?.time`).
    private static func parseHttpDate(_ value: String?) -> Int64? {
        guard let value, let date = httpDateFormatter.date(from: value) else { return nil }
        return Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// RFC 1123 формат, tz-независимый (`en_US_POSIX` + фиксированный GMT).
    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
