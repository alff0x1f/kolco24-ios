//
//  TrackSampling.swift
//  kolco24
//
//  Чистый даунсемплинг фиксов трека. **Не порт** — на Android движок сам держал
//  интервал захвата ~15 с; CoreLocation `liveUpdates` отдаёт ~1 Гц, поэтому
//  прореживание нужно на нашей стороне, чтобы выровнять плотность данных с Android
//  (и не раздувать БД/выгрузку). Форма — тот же nullable-сентинел, что у
//  `shouldLiveUpload` (первый фикс всегда сохраняется, reboot/overflow-safe).
//

import Foundation

/// Целевой интервал прореживания фиксов трека (мс) для профиля Precise. CoreLocation
/// отдаёт ~1 Гц — эта константа выравнивает плотность данных с Android-движком (тот
/// сам держал интервал захвата 15 с). Economy-профиль (больший интервал) — этап 9.
let TRACK_SAMPLE_INTERVAL_MS: Int64 = 15_000

/// Решить, сохранять ли текущий фикс: ни одного ещё не сохранили в этой сессии
/// ([lastKeptElapsed] == nil) → всегда true (первый фикс сохраняется сразу,
/// независимо от того, как долго устройство было включено), иначе true, как только
/// монотонная дельта с последнего сохранённого достигает [intervalMs]. **Nullable**-
/// сентинел (не `0`) reboot-safe: `nowElapsed` — монотонное время с загрузки, так что
/// запись, начатая в пределах 15 с после ребута, не отбросила бы первый фикс с `0`-
/// базой — и overflow-safe. [nowElapsed] — из `fix.elapsedRealtimeNanos / 1_000_000`.
func shouldKeepFix(nowElapsed: Int64, lastKeptElapsed: Int64?, intervalMs: Int64) -> Bool {
    guard let lastKeptElapsed else { return true }
    return nowElapsed - lastKeptElapsed >= intervalMs
}
