//
//  Segments.swift
//  kolco24
//
//  Чистые решения GPS-трека. Порт 1:1 чистого верха `TrackRecordingService.kt`
//  (сам `Service` — Android — не портируется): выбор id сессии записи на
//  fresh-start пути и троттлинг live-загрузок. Никакого Android.
//

/// Решить id сессии записи [segmentId] на fresh-start пути: минтить новый, когда нет текущего сегмента
/// (первый старт или после teardown, сбросившего его в nil) или когда teardown был в полёте
/// ([wasTearingDown] — старт замещает разбираемую сессию, логически это новая); иначе сохранить
/// [current], чтобы дублирующий/идемпотентный старт-интент оставался одним сегментом. Чистая, поэтому
/// матрица stop→start / идемпотентный повторный вход JVM-тестируется (конвенция репо).
func nextSegmentId(current: String?, wasTearingDown: Bool, mint: () -> String) -> String {
    (wasTearingDown || current == nil) ? mint() : current!
}

/// Минимальный интервал между live-загрузками в записи: 10 мин. Применяется к **обоим** профилям —
/// Precise (~60 с батчи) срабатывает ~каждые 10 мин; Economy (~180 с батчи) — на батче, пересекающем
/// 600 с, ~каждые 12 мин. Одна константа, без пер-профильной конфигурации (переиспользуется GPS-wake,
/// без лишних пробуждений устройства).
let LIVE_UPLOAD_MIN_INTERVAL_MS: Int64 = 600_000

/// Решить, запускать ли live-загрузку для текущего батча фиксов: ни разу не грузили в этой сессии
/// ([lastUploadElapsed] == nil) → всегда true (первый батч срабатывает сразу, независимо от того, как
/// долго устройство было включено), иначе true, как только монотонная дельта с последней загрузки
/// достигает [minIntervalMs]. **Nullable**-сентинел (не `0`) reboot-safe: `elapsedRealtime()` — время
/// с загрузки, так что запись, начатая в пределах 10 мин после ребута, не сработала бы на первом батче
/// с `0`-базой — и overflow-safe (нет `now - Long.MIN_VALUE`). Чистая, поэтому
/// граница/первый-батч матрица JVM-тестируется (конвенция репо).
func shouldLiveUpload(nowElapsed: Int64, lastUploadElapsed: Int64?, minIntervalMs: Int64) -> Bool {
    guard let lastUploadElapsed else { return true }
    return nowElapsed - lastUploadElapsed >= minIntervalMs
}
