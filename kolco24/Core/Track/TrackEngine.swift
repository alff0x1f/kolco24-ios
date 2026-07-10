//
//  TrackEngine.swift
//  kolco24
//
//  Шов движка GPS-трека — граница между чистым `TrackRecorder` (App/) и платформенным
//  `CoreLocationTrackEngine` (Location/). Foundation-only (без CoreLocation), чтобы `TrackRecorder`
//  тестировался через `FakeTrackEngine` со скриптованным стримом.
//
//  Отличие от Android-слоя движков (`LocationEngineFactory`/`FusedLocationEngine`/`LegacyLocationEngine`):
//  на iOS один движок (`CLLocationUpdate.liveUpdates`), поэтому фабрика/выбор типа не портируются —
//  остаётся только этот протокол-seam для тестируемости.
//
//  Без `flush()`: CoreLocation отдаёт фиксы сразу (нет maxDelay-буфера, как у Fused), поэтому
//  lossless-стоп упрощается до «отменить цикл, дописать пришедшее» — `FLUSH_TIMEOUT_MS` из Kotlin
//  не переносится. Конец стрима = движок остановлен (`stop()` или системная остановка обновлений).
//

import Foundation

/// Источник сырых GPS-фиксов для записи трека. Один длинный `fixes()`-стрим на сессию записи;
/// конец стрима означает, что движок остановлен (нет отдельного `flush` — фиксы приходят сразу).
protocol TrackEngine: AnyObject {
    /// Поток сырых фиксов (`RawFix`) от системы локации. Завершается, когда движок остановлен.
    func fixes() -> AsyncStream<RawFix>
    /// Остановить обновления и завершить стрим. Идемпотентен.
    func stop()
}
