//
//  CurrentLocation.swift
//  kolco24
//
//  One-shot GPS-шов взятия на КП: чистое значение сырого фикса (`RawFix`,
//  зеркало `data/track/TrackModels.kt`), протокол-граница провайдера
//  (`CurrentLocationProvider`, зеркало `CurrentLocationProvider.kt`; прод
//  `CoreLocationProvider` — задача 6) и чистые хелперы санитизации/свежести,
//  вынесенные из `MarkRepository.attachLocation` / `LegacyCurrentLocationProvider`.
//
//  Контракт (зеркало Kotlin): `current` возвращает **один свежий** фикс или `nil`,
//  **никогда не бросает** — таймаут / нет разрешения / нет провайдера / несвежий
//  кэш дают `nil` (строка взятия остаётся без координаты; «нет координаты» строго
//  лучше устаревшей для анти-фрода). Свежесть обязательна.
//

import Foundation

/// Дефолтный таймаут одного фикса (мс) — зеркало Kotlin-дефолта
/// `CurrentLocationProvider.current(timeoutMs = 8_000)`.
let DEFAULT_LOCATION_TIMEOUT_MS: Int64 = 8_000

/// Максимальный возраст (мс, монотонный по `elapsedRealtimeNanos`), при котором фикс
/// ещё «свежий». Зеркало `MAX_FIX_AGE_MS = 10_000L`: для анти-фрода «нет координаты»
/// лучше устаревшей.
let MAX_FIX_AGE_MS: Int64 = 10_000

/// Один сырой фикс, как он выходит из движка локации — чистое гео-значение **без**
/// boot-/trusted-полей (они инжектятся позже). Зеркало `data/track/TrackModels.kt`
/// `data class RawFix`.
///
/// - `elapsedRealtimeNanos`: монотонный момент фикса (`Location.elapsedRealtimeNanos`),
///   источник свежести и времени точки.
/// - `altitude`/`verticalAccuracyMeters` опциональны: `hasAltitude()`/
///   `hasVerticalAccuracy()` могут быть false (сетевой фикс часто без обоих).
struct RawFix: Equatable {
    let lat: Double
    let lon: Double
    let accuracy: Float
    let altitude: Double?
    let verticalAccuracyMeters: Float?
    let gpsTimeMs: Int64
    let elapsedRealtimeNanos: Int64
}

/// One-shot шов свежей локации (без foreground-сервиса) — штампует анти-фрод
/// координату на строку взятия в момент скана чипа КП. Зеркало
/// `interface CurrentLocationProvider`.
///
/// Возвращает **один свежий** фикс или `nil`; **никогда не бросает** (таймаут /
/// нет разрешения / нет провайдера / любая платформенная ошибка → `nil`).
protocol CurrentLocationProvider {
    /// Один свежий фикс или `nil`. Никогда не бросает.
    func current(timeoutMs: Int64) async -> RawFix?

    /// Заранее запросить разрешение на геолокацию «при использовании» — вызывается один раз при
    /// первом открытии скан-оверлея (как в Android). No-op по умолчанию: провайдеры без разрешений
    /// (тесты, `NoLocationProvider`) его игнорируют, прод `CoreLocationProvider` — переопределяет.
    func requestWhenInUseAuthorization()
}

extension CurrentLocationProvider {
    /// Удобный вызов с дефолтным таймаутом (Swift-протокол не несёт значения по
    /// умолчанию в требовании, в отличие от Kotlin-`interface`).
    func current() async -> RawFix? {
        await current(timeoutMs: DEFAULT_LOCATION_TIMEOUT_MS)
    }

    /// По умолчанию — no-op (разрешение нужно только продовому `CoreLocationProvider`).
    func requestWhenInUseAuthorization() {}
}

/// Санитизированные значения одного фикса, готовые к колоночному UPDATE
/// `MarkStore.attachLocation`. Зеркало веток `MarkRepository.attachLocation`
/// (261–273): невалидная `accuracy` (`Float.MAX_VALUE`) и `gpsTimeMs <= 0`
/// схлопываются в `nil`; `elapsedRealtimeNanos` конвертируется в мс.
struct SanitizedFix: Equatable {
    let lat: Double
    let lon: Double
    let accuracy: Float?
    let altitude: Double?
    let verticalAccuracyMeters: Float?
    let gpsTimeMs: Int64?
    let elapsedRealtimeAt: Int64
}

/// Санитизировать сырой фикс в набор колонок `attachLocation`. Зеркало
/// `MarkRepository.attachLocation`: `accuracy.takeIf { it != Float.MAX_VALUE }`,
/// `gpsTimeMs.takeIf { it > 0L }`, `elapsedRealtimeAt = elapsedRealtimeNanos / 1_000_000`.
/// (`Float.MAX_VALUE` Kotlin ≡ `Float.greatestFiniteMagnitude` Swift.)
func sanitizeFix(_ fix: RawFix) -> SanitizedFix {
    SanitizedFix(
        lat: fix.lat,
        lon: fix.lon,
        accuracy: fix.accuracy == .greatestFiniteMagnitude ? nil : fix.accuracy,
        altitude: fix.altitude,
        verticalAccuracyMeters: fix.verticalAccuracyMeters,
        gpsTimeMs: fix.gpsTimeMs > 0 ? fix.gpsTimeMs : nil,
        elapsedRealtimeAt: fix.elapsedRealtimeNanos / 1_000_000
    )
}

/// Свеж ли фикс относительно текущего монотонного момента `nowElapsedNanos`. Зеркало
/// `LegacyCurrentLocationProvider.isFresh`: `ageMs = (now - fixNanos) / 1_000_000`,
/// свеж ⇔ `ageMs in 0..maxAgeMs` — возраст неотрицателен (фикс не в будущем) И в
/// пределах порога. Оба аргумента — наносекунды `elapsedRealtimeNanos`.
func isFixFresh(_ fix: RawFix, nowElapsedNanos: Int64, maxAgeMs: Int64 = MAX_FIX_AGE_MS) -> Bool {
    let ageMs = (nowElapsedNanos - fix.elapsedRealtimeNanos) / 1_000_000
    return ageMs >= 0 && ageMs <= maxAgeMs
}
