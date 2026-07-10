//
//  CLLocationMapping.swift
//  kolco24
//
//  Общий чистый маппинг `CLLocation → RawFix` + монотонные наносекунды, разделяемые обоими
//  Location-адаптерами (`CoreLocationProvider` — одноразовый фикс, stage 5; `CoreLocationTrackEngine` —
//  поток фиксов трека, stage 8). Правила маппинга едины по контракту, поэтому живут в одном месте.
//  `import CoreLocation` остаётся под `Location/` (grep-инвариант не нарушается).
//

import CoreLocation

/// Разделяемый маппинг CLLocation → RawFix для Location-адаптеров.
enum CLLocationMapping {

    /// `CLLocation → RawFix` при монотонном моменте `nowNanos`. Невалидная `horizontalAccuracy` (< 0) →
    /// `Float.greatestFiniteMagnitude` (санитайзер схлопнёт в `nil`); высота/верт.точность — только при
    /// `verticalAccuracy > 0`. `elapsedRealtimeNanos = nowNanos − wall-возраст фикса`.
    static func makeRawFix(from loc: CLLocation, nowNanos: Int64) -> RawFix {
        let ageSeconds = max(0, Date().timeIntervalSince(loc.timestamp))
        let ageNanos = Int64(ageSeconds * 1_000_000_000)
        let hAcc = loc.horizontalAccuracy
        let vAccValid = loc.verticalAccuracy > 0
        return RawFix(
            lat: loc.coordinate.latitude,
            lon: loc.coordinate.longitude,
            accuracy: hAcc >= 0 ? Float(hAcc) : .greatestFiniteMagnitude,
            altitude: vAccValid ? loc.altitude : nil,
            verticalAccuracyMeters: vAccValid ? Float(loc.verticalAccuracy) : nil,
            gpsTimeMs: Int64((loc.timestamp.timeIntervalSince1970 * 1000).rounded()),
            elapsedRealtimeNanos: nowNanos - ageNanos
        )
    }

    /// Множитель `mach_continuous_time()` → наносекунды (timebase; кэшируется один раз).
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Монотонные наносекунды, идущие во сне устройства (аналог `elapsedRealtimeNanos`).
    static func continuousNanos() -> Int64 {
        let ticks = mach_continuous_time()
        return Int64(ticks &* UInt64(timebase.numer) / UInt64(timebase.denom))
    }
}
