# Track spike filter + «Все точки» (iOS port)

Port of Android #95 (`kolco24_app_v2` commit `9913f7e`, plan `docs/plans/completed/20260926-track-spike-filter.md`
there). The algorithm, constants and test cases are 1:1; read the Android plan for the rationale and worked examples.

## What changed
- `Core/Track/TrackLines.swift` — `haversineMeters`, `isReachable`, `isShortChain`, `trackLines(_:filter:)`
  (hard cap 500 m, 14 m/s reachability with accuracy allowance and 1 s floor, head/interior/tail rules for short
  chains, lines never cross `segmentId` runs). Replaces `filterPoints` (50 m cutoff, removed).
  `FilteredTrack` = lines + flat points + `hiddenCount`; `FilteredTrackMemo` caches it for computed model properties.
- `buildGpx(lines:trackName:)` — one `<trkseg>` per line; no own `segmentId` grouping.
- `Core/Stores/TrackFilterPreference` — `@Observable`, `UserDefaults` key `track_show_all_points` (same as Android).
  Lives in `AppEnvironment`; `MapModel`, `TeamModel`, `SettingsModel` read it directly.
- Server upload stays raw.

## iOS-specific choices
- Kotlin `TrackPointLike` has no Swift analog: the Swift core has one point type (`TrackPoint`), so the filter is
  not generic (the `genericTypePreserved` test is dropped).
- Android computes lines in `produceState` on `Dispatchers.Default`; here the models memoize `FilteredTrack`
  (`FilteredTrackMemo`, recompute only on a new points array or a toggle). At 15 s sampling a day is ~6k points —
  one O(n) pass on main is cheap.
- Map (MapKit instead of MapLibre GeoJSON): lines with ≥ 2 points → one `MKMultiPolyline`; 1-point lines →
  `TrackDotAnnotation` (7 pt orange dot, non-interactive) — the analog of the Android `CircleLayer`, so the first fix
  of a live tail after a break is visible at once. Camera fit uses the flattened lines.
- Map chip «Все точки · +N»: top-leading capsule under the «нет оффлайн-карты» line; shown when the filter hid points
  or the mode is on; toggling does not move the camera.
- Settings: toggle row «Показывать все точки трека» / «Без фильтрации выбросов GPS» in «Запись трека».
- Track card: «на карте N» under the «Точек» metric and after the count in the live recording header, only when
  the filter hid points. No «Нет точек для экспорта» toast (iOS has no share toast): the «Поделиться GPX» button
  just hides when no line is left.
