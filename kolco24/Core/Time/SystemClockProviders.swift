//
//  SystemClockProviders.swift
//  kolco24
//
//  Продовые провайдеры времени для `TrustedClock` (в тестах инъектируются фейки).
//  Аналоги Android-источников из `TrustedClock.kt`:
//    - elapsed = `mach_continuous_time()` в мс — монотонные часы, идущие **во сне** устройства
//      (аналог `SystemClock.elapsedRealtime()`). `systemUptime` / `CLOCK_UPTIME_RAW` во сне стоят,
//      поэтому не подходят: 20-с окно сканирования и якорь прыгнули бы после сна.
//    - wall = `Date().timeIntervalSince1970 * 1000` (аналог `System.currentTimeMillis()`).
//    - bootCount = всегда `nil`: аналога `Settings.Global.BOOT_COUNT` на iOS нет. Логика
//      `TrustedClock` уже трактует `nil` как «нет свидетельства ребута» и ловит ребут по регрессии
//      монотонных часов относительно сохранённого якоря.
//

import Foundation

/// Продовые провайдеры времени: инъектируются в `TrustedClock` в приложении.
enum SystemClockProviders {

    /// Множитель `mach_continuous_time()` → наносекунды (timebase; кэшируется один раз).
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Монотонные часы в мс, идущие во сне устройства (аналог `elapsedRealtime()`).
    static func elapsedRealtimeMs() -> Int64 {
        let ticks = mach_continuous_time()
        let nanos = ticks &* UInt64(timebase.numer) / UInt64(timebase.denom)
        return Int64(nanos / 1_000_000)
    }

    /// Wall-часы устройства в epoch мс (аналог `System.currentTimeMillis()`).
    static func wallClockMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    /// Идентичность boot-сессии — на iOS недоступна, всегда `nil`.
    static func bootCount() -> Int? {
        nil
    }

    /// Собрать `TrustedClock` на продовых провайдерах.
    /// - Parameters:
    ///   - persist: персистенция якоря (`ClockAnchorStore` этапа 2).
    ///   - persisted: якорь, прочитанный при старте (тёплый старт).
    static func makeClock(
        persist: @escaping (ClockAnchor) throws -> Void = { _ in },
        persisted: ClockAnchor? = nil
    ) -> TrustedClock {
        TrustedClock(
            elapsedProvider: elapsedRealtimeMs,
            wallProvider: wallClockMs,
            bootCountProvider: bootCount,
            persist: persist,
            persisted: persisted
        )
    }
}

extension TrustedClock {

    /// Продовая фабрика: системные провайдеры времени + персистенция якоря через `ClockAnchorStore`
    /// (тёплый старт из `store.read()`). Собственно подключение к приложению — этапы 3–4.
    static func makeDefault(
        store: ClockAnchorStore = .fromUserDefaults()
    ) -> TrustedClock {
        SystemClockProviders.makeClock(
            persist: { store.write($0) },
            persisted: store.read()
        )
    }
}
