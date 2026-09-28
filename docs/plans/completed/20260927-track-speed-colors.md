# Track speed colors + stop markers (map tab)

## What changed
- `Core/Track/TrackSpeed.swift` — `speedBand`, `stepSpeedsMps` (net displacement over a ~90 s window, never across
  a > 3 min step), `stepStrokes` (long step with ends within `clamp(acc₁+acc₂, 50, 150)` m → `.stop`, else `.gap`), `speedRuns`, `trackStops`
  (`.stop` runs ≥ 3 min), `formatStopDuration`, `speedBandLegendLabel`, `SpeedTrack` + `SpeedTrackMemo`.
- `Core/Stores/TrackColorPreference` — `@Observable`, key `track_color_by_speed`, default true (also in `inMemory`).
- `MapModel` — `colorBySpeed`, `speedRuns` (nil → plain track), `stopPins` (`MapStopPin`); off under «Все точки».
- Settings — «Цвет трека по скорости» row in «Запись трека», disabled under «Все точки».
- Map — casing under band runs, one `MKMultiPolyline` per stroke, dashed grey gap; `StopAnnotation` capsules
  (diffed by `MapStopPin`, so an open callout survives other stops changing; below КП pins); legend capsule
  under the «Все точки» chip.
- Codex review follow-up: a long step is a stop by **distance**, not by average speed (a 1 h GPS outage
  while moving with ends 800 m apart averaged 0.8 km/h → false «1 ч 00 мин» stop). Window growth is O(n·k)
  where k = points per 90 s; linear only because the recorder keeps ≤ 1 fix per 15 s (`shouldKeepFix`).
- `DesignTokens` — non-adaptive `speedStop…speedFast`, `speedGap`; `SpeedStroke.color`.

## Overview
- Color the team track on the map by movement speed, and mark long stops with a «12 мин» label.
- Goal: after (or during) a rogaine, see where the team lost time — stops, slow bushwhacking, КП search.
- Target: on foot with a backpack over rough terrain. A bike just falls into the top band.
- On by default. Settings has a toggle to turn it off (plain orange track, as today).
- iOS-first. Algorithm and constants are pure and simple, so they can be ported to Android later.
- Display only: DB, upload and GPX stay unchanged.

## Context (from discovery)
- `kolco24/Core/Track/TrackLines.swift` — `trackLines`, `haversineMeters`, `FilteredTrack`, `FilteredTrackMemo`.
- `kolco24/Core/Track/TrackPoints.swift` — `trackPointTimeMs` (`trustedMs ?? wallMs`), `sortedTrackPoints`.
- `kolco24/Core/Track/TrackSampling.swift` — `TRACK_SAMPLE_INTERVAL_MS = 15_000` (one point per 15 s).
- `kolco24/App/MapModel.swift` — `trackLines`, `showAllPoints`, `filteredTrack` via `trackMemo`.
- `kolco24/Map/TrackMapView.swift` — one `MKMultiPolyline` (`kolcoOrange`, width 3), `TrackDotAnnotation`,
  `CheckpointAnnotation`, `Coordinator.rendererFor`.
- `kolco24/MapTabView.swift` — «Все точки» chip overlay (pattern for the legend overlay).
- `kolco24/Core/Stores/TrackFilterPreference.swift` — `@Observable` preference with `load`/`save` seams (pattern).
- `kolco24/App/SettingsModel.swift`, `kolco24/SettingsView.swift` — «Запись трека» section with the «Все точки» toggle.
- `kolco24/App/AppEnvironment.swift` — owns `trackFilterPreference` (prod + preview/test construction).
- `kolco24/Location/CoreLocationTrackEngine.swift:76` — `liveUpdates(.fitness)`, `isStationary` updates are
  skipped: a phone at rest yields **no fixes**, so an iOS stop is usually one long step with ~0 displacement.
- Tests: `kolco24Tests/Core/TrackLinesTests.swift`, `kolco24Tests/Core/TrackFilterPreferenceTests.swift`,
  `kolco24Tests/App/MapModelTests.swift`, `kolco24Tests/App/SettingsModelTests.swift`.

## Development Approach
- **testing approach**: TDD — write failing tests for each pure function first, then the code.
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change
- maintain backward compatibility

## Testing Strategy
- **unit tests**: Swift Testing suites over synthetic `TrackPoint`s (points along a meridian:
  1 m ≈ 1/111 195° lat, fixed time step). Real stores over `AppDatabase.makeInMemory()` for `MapModelTests`.
- `Map/` and SwiftUI views have no unit tests (device-only, project convention) — all behavior sits in the
  pure core and `MapModel`.
- no e2e tests in this project.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview
- Pure core `Core/Track/TrackSpeed.swift` turns the filtered `trackLines` into:
  - **speed runs** — consecutive steps with the same speed band, merged into one polyline each;
  - **stops** — places where the track stayed within a small radius for ≥ 3 min.
- `MapModel` exposes runs + stops (memoized) only when the mode is active.
- `TrackMapView` draws a dark casing under the whole track, then one `MKMultiPolyline` per band on top.
  Gap steps draw grey and dashed. Stops are small capsule annotations «12 мин» with a callout.
- `MapTabView` shows a compact legend when the speed mode is active.
- Mode is active when `colorBySpeed == true` **and** «Все точки» is off. With raw points spikes give fake
  speeds, so «Все точки» always draws the plain orange track without stops.

### Key design decisions
- **Window speed, net displacement.** Point-to-point speed at 15 s sampling is dominated by GPS noise
  (walking 4 km/h = ~17 m per step, noise is 10–30 m). Speed for a step = straight distance between the ends of
  a ~90 s window around it / window duration. Stationary noise of 10 m over 90 s gives ~0.6 km/h — stays in the
  «stop» band. Summing path length instead would add noise on every step (a standing phone would "walk" 3 km/h).
  Net displacement slightly underestimates a zig-zag, which is acceptable. Known effects, not bugs:
  an out-and-back leg to a КП turns ~90 s around the turn into «stop»/«slow»; under canopy with 30 m noise a
  standing phone can read as «slow» (~1.7 km/h) — tuned on real data after release.
- **Fixed km/h bands**, not percentiles: colors are comparable across days and teams, the legend is simple.
- **Discrete colors**, not `MKGradientPolylineRenderer`: crisp legend, 5–6 overlays total, cheap at ~6k points/day.
- **Long step** = a step longer than 3 min. A window never crosses it. It is classified by its own speed:
  < 1 km/h → a stop at rest (the normal iOS case: no fixes while stationary) → `.band(.stop)`; otherwise
  `.gap` (GPS hole while moving — the average would look like slow walking).
- **Stops come from the strokes, not from a separate radius detector.** A stop = a maximal run of consecutive
  `.band(.stop)` steps inside one line lasting ≥ 3 min. Markers and colors always agree, one threshold, O(n).
  (A running-centroid radius detector was rejected: at 1–2 km/h the centroid lags the walker, so slow
  bushwhacking gets a chain of false «3 мин» markers.)
- **Accepted limitation:** a stop in progress is invisible until the next fix after moving on (no fixes while
  stationary). The live tail just ends at the stop place.
- New preference class instead of a second flag in `TrackFilterPreference`: keeps the existing class, its init
  signature and tests untouched (duplication of ~30 lines over coupling).

## Technical Details

### Constants (`Core/Track/TrackSpeed.swift`)
| Name | Value | Meaning |
|---|---|---|
| `SPEED_WINDOW_MS` | 90_000 | target window span for a step's speed |
| `SPEED_GAP_MS` | 180_000 | a step longer than this is a gap |
| `SPEED_BAND_LIMITS_KMH` | [1, 3, 5, 7] | band lower bounds (lower-inclusive) |
| `STOP_MIN_DURATION_MS` | 180_000 | minimum stop duration |

### Types
```swift
enum SpeedBand: Int, CaseIterable, Equatable {
    case stop   // < 1 km/h
    case slow   // 1–3
    case walk   // 3–5
    case brisk  // 5–7
    case fast   // ≥ 7
}

enum SpeedStroke: Equatable { case band(SpeedBand), gap }

struct SpeedRun: Equatable {
    let stroke: SpeedStroke
    let points: [TrackPoint]   // ≥ 2; neighbouring runs share the boundary point
}

struct TrackStop: Equatable {
    let lat: Double, lon: Double   // centroid
    let startMs: Int64, endMs: Int64
}

struct SpeedTrack: Equatable { let runs: [SpeedRun]; let stops: [TrackStop] }
```

### Functions
- `speedBand(kmh: Double) -> SpeedBand` — first band whose lower bound ≤ kmh (1.0 → `.slow`, 0.99 → `.stop`).
- `stepSpeedsMps(_ line: [TrackPoint]) -> [Double]` — `line.count - 1` values.
  Long step (`dt > SPEED_GAP_MS`): its own speed `haversine(p[k], p[k+1]) / dt`.
  Normal step `k`: start with `a = k, b = k + 1`; while `t[b] - t[a] < SPEED_WINDOW_MS`, try to grow left
  (if `a > 0` and step `a-1` is not long), then right (if `b < last` and step `b` is not long), alternating;
  if one side is blocked keep growing the other; stop when neither can grow (a line shorter than the window
  uses the whole line). Speed = `haversineMeters(p[a], p[b]) / max(t[b] - t[a], 1000 ms)`.
- `stepStrokes(_ line: [TrackPoint]) -> [SpeedStroke]` — normal step → `.band(speedBand(kmh:))`; long step →
  `.band(.stop)` if < 1 km/h, else `.gap`.
- `speedRuns(_ lines: [[TrackPoint]]) -> [SpeedRun]` — per line, merge consecutive equal strokes; one-point
  lines give no runs.
- `trackStops(_ lines: [[TrackPoint]]) -> [TrackStop]` — per line, every maximal run of `.band(.stop)` steps
  with `t[end] - t[start] ≥ STOP_MIN_DURATION_MS`; centroid = mean lat/lon of the run's points.
  (Built from the same `stepStrokes` as `speedRuns`; `SpeedTrack(lines:)` computes strokes once.)
- `formatStopDuration(ms: Int64) -> String` — «3 мин», «59 мин», «1 ч 05 мин», «2 ч 00 мин» (minutes floored).
- `SpeedTrack(lines:)` + `SpeedTrackMemo` (same pattern as `FilteredTrackMemo`, keyed on the lines array).

### Preference (`Core/Stores/TrackColorPreference.swift`)
- `@Observable final class TrackColorPreference`, `private(set) var colorBySpeed: Bool`, `setColorBySpeed(_:)`.
- `UserDefaults` key `track_color_by_speed`; default **true** (`defaults.object(forKey:) as? Bool ?? true` —
  `bool(forKey:)` would default to false).
- `AppEnvironment.inMemory` must keep the same default:
  `load: { prefs.get(key).map { $0 == "true" } ?? true }` (copying the `== "true"` pattern of
  `trackFilterPreference` would give false).

### MapModel
- `var speedTrack: SpeedTrack?` — `nil` unless `colorBySpeed && !showAllPoints`; built from `filteredTrack.lines`
  via `SpeedTrackMemo`.
- Exposed to the view as Foundation-only values: `speedRuns: [(stroke: SpeedStroke, coords: [(lat, lon)])]?`
  and `stopPins: [MapStopPin]` (`lat`, `lon`, `label` = `formatStopDuration`, `startMs`, `endMs`).
- `trackLines` stays — used for the plain mode and for the casing + camera fit.

### Map rendering (`Map/TrackMapView.swift`)
- New inputs `speedRuns` (optional) and `stopPins`.
- Plain mode (`speedRuns == nil`): unchanged — one orange `MKMultiPolyline`.
- Speed mode: casing `MKMultiPolyline` of the **band runs only** (black ~55 % alpha, width 5 — not under `.gap`,
  or the dash would read as a solid dark line), then one `MKMultiPolyline` per stroke present (width 3, round
  caps). Gap stroke: grey, `lineDashPattern = [4, 6]`, no casing.
- Single-fix `TrackDotAnnotation`s stay orange in both modes (a fresh live-tail fix has no speed yet).
- Coordinator keeps `trackOverlays: [MKOverlay]` and a `[ObjectIdentifier: TrackStrokeStyle]` map for
  `rendererFor`; all are removed and re-added on each `applyData` (as today with the single polyline).
- `StopAnnotation` + view: dark capsule, white `Font.mono` label «12 мин»; `canShowCallout` with title
  «Стоянка 12 мин» and subtitle «14:05–14:17» (same time formatting as the КП pins). Lower `displayPriority`
  and `zPriority` than `CheckpointAnnotation` (stops often sit at a КП). Replaced only when `stopPins` actually
  changes (Coordinator keeps the last value) — `updateUIView` runs on every fix/progress tick and a blind
  re-add would close an open callout.

### Colors (`DesignTokens.swift`)
- Non-adaptive tokens (the map background decides contrast, not the app theme). Plasma-like start values,
  to be tuned on a real topo tile:
  `speedStop #3B0F70`, `speedSlow #8C2981`, `speedWalk #DE4968`, `speedBrisk #FE9F6D`, `speedFast #F0F921`,
  `speedGap #8E8E93`.
- `extension SpeedBand { var color: Color }` next to the tokens (Core stays framework-free).

### Legend (`MapTabView.swift`)
- Small capsule (material background) in the existing `topOverlay` stack, under the «Все точки» chip:
  5 swatches + «<1 · 1–3 · 3–5 · 5–7 · 7+ км/ч». Not at the bottom — that is the download CTA/progress card
  (`availabilityOverlay`) and the MapKit logo/«Legal».
- Shown only when `speedRuns` is non-nil and non-empty.

### Settings
- New row in «Запись трека» above «Показывать все точки трека»: «Цвет трека по скорости» /
  sub «Стоянки от 3 мин — отметкой на карте». When «Все точки» is on, the row sub reads
  «Недоступно при показе всех точек» and the toggle is disabled.

## What Goes Where
- **Implementation Steps** (`[ ]` checkboxes): code, tests, docs in this repo.
- **Post-Completion** (no checkboxes): on-device checks with a real track, Android port.

## Implementation Steps

### Task 1: Speed bands and window speed

**Files:**
- Create: `kolco24/Core/Track/TrackSpeed.swift`
- Create: `kolco24Tests/Core/TrackSpeedTests.swift`

- [x] write tests for `speedBand(kmh:)`: each band, exact boundaries (0.99/1.0, 3.0, 5.0, 7.0), 0, very large
- [x] write tests for `stepSpeedsMps`: steady 4 km/h line → ~1.11 m/s on every step; stationary line with
      deterministic alternating ±10 m one-axis jitter → all < 1 km/h; long step (> 180 s) → its own speed;
      window does not cross a long step (each side computed only from its side); one-sided window at line
      start and end (keeps growing on the open side); line shorter than 90 s uses the whole line; 2-point line;
      zero dt uses the 1 s floor
- [x] implement constants, `SpeedBand`, `speedBand(kmh:)`, `stepSpeedsMps`
- [x] run tests - must pass before task 2

### Task 2: Step strokes and speed runs

**Files:**
- Modify: `kolco24/Core/Track/TrackSpeed.swift`
- Modify: `kolco24Tests/Core/TrackSpeedTests.swift`

- [x] write tests for `stepStrokes`: normal steps map to bands; long step with ~0 displacement → `.band(.stop)`;
      long step with 700 m displacement → `.gap`
- [x] write tests for `speedRuns`: single band → one run with all points; band change → two runs sharing the
      boundary point; `.gap` run between speed runs; one-point lines → no runs; multiple lines never merge into
      one run; empty input
- [x] implement `SpeedStroke`, `SpeedRun`, `stepStrokes(_:)`, `speedRuns(_:)`
- [x] run tests - must pass before task 3

### Task 3: Stops and duration format

**Files:**
- Modify: `kolco24/Core/Track/TrackSpeed.swift`
- Modify: `kolco24Tests/Core/TrackSpeedTests.swift`

- [x] write tests for `trackStops` (primary case first — iOS gives no fixes at rest): walking, then two points
      10 min and 5 m apart, then walking → one stop with correct start/end and centroid; 4 min of 0.5 km/h
      drift at 15 s sampling → stop; steady 1 km/h walking for 10 min → no stop; 179 s → no stop, 180 s → stop;
      long step with 700 m displacement → no stop; two separate stops; stops never cross lines
- [x] write tests for `formatStopDuration`: 3 min, 59 min, 60 min → «1 ч 00 мин», 65 min → «1 ч 05 мин», seconds floored
- [x] implement `TrackStop`, `trackStops(_:)`, `formatStopDuration(ms:)`
- [x] implement `SpeedTrack(lines:)` and `SpeedTrackMemo`; test memo returns the cached value for the same array
      and recomputes for a new one
- [x] run tests - must pass before task 4

### Task 4: Color-by-speed preference

**Files:**
- Create: `kolco24/Core/Stores/TrackColorPreference.swift`
- Create: `kolco24Tests/Core/TrackColorPreferenceTests.swift`
- Modify: `kolco24/App/AppEnvironment.swift`

- [x] write tests (fake store, as `TrackFilterPreferenceTests`): loads stored `false`/`true`; `setColorBySpeed`
      updates value and calls `save`; `fromUserDefaults` on a scratch `UserDefaults(suiteName:)` defaults to
      `true` when the key is absent (clean up with `removePersistentDomain(forName:)`)
- [x] implement `TrackColorPreference` (idiom of `TrackFilterPreference`)
- [x] wire into `AppEnvironment` (prod `fromUserDefaults()`; `inMemory` with default `true`, see Technical Details)
- [x] run tests - must pass before task 5

### Task 5: MapModel speed track

**Files:**
- Modify: `kolco24/App/MapModel.swift`
- Modify: `kolco24Tests/App/MapModelTests.swift`

- [x] write tests: fresh `inMemory` env → speed mode on; speed on + filter on → `speedRuns` non-nil, `stopPins`
      for a stop;
      `colorBySpeed == false` → `speedRuns == nil`, no stop pins; «Все точки» on → `speedRuns == nil`, no stop
      pins; empty track → empty runs; `trackLines` unchanged in all modes
- [x] add `MapStopPin`, `speedRuns`, `stopPins`, `SpeedTrackMemo` usage
- [x] run tests - must pass before task 6

### Task 6: Settings toggle

**Files:**
- Modify: `kolco24/App/SettingsModel.swift`
- Modify: `kolco24/SettingsView.swift`
- Modify: `kolco24Tests/App/SettingsModelTests.swift`

- [x] write tests: `colorTrackBySpeed` get/set goes through `TrackColorPreference`; `colorBySpeedAvailable` is
      false while «Все точки» is on
- [x] add `colorTrackBySpeed` and `colorBySpeedAvailable` to `SettingsModel`
- [x] add the «Цвет трека по скорости» row to «Запись трека» (disabled + alternative sub when unavailable)
- [x] run tests - must pass before task 7

### Task 7: Speed polylines on the map

**Files:**
- Modify: `kolco24/DesignTokens.swift`
- Modify: `kolco24/Map/TrackMapView.swift`
- Modify: `kolco24/MapTabView.swift`

- [x] add speed color tokens and `SpeedBand.color` / gap color in `DesignTokens.swift`
- [x] `TrackMapView`: `speedRuns` input; casing under band runs only + per-stroke `MKMultiPolyline`s; dashed gap
      without casing; style lookup in `Coordinator.rendererFor`; plain mode unchanged
- [x] `MapTabView`: pass `speedRuns`
- [x] no unit tests for `Map/` and views (project convention) — behavior covered by tasks 1–6; build must succeed
- [x] run full test suite + build - must pass before task 8

### Task 8: Stop annotations and legend

**Files:**
- Modify: `kolco24/Map/TrackMapView.swift`
- Modify: `kolco24/MapTabView.swift`

- [x] `StopAnnotation` + view: label, callout, priorities below КП pins; replaced only when `stopPins` changes
- [x] `MapTabView`: pass `stopPins`; legend in `topOverlay` under the «Все точки» chip, only in speed mode
- [x] no unit tests (device-only); build must succeed
- [x] run full test suite + build - must pass before task 9

### Task 9: Verify acceptance criteria
- [x] verify all requirements from Overview are implemented
- [x] verify edge cases: empty track, one-point lines, «Все точки» on, speed off, live tail growing during
      recording; accepted limitation: a stop in progress is not shown until the team moves on
- [x] grep invariants: no `import GRDB`/UIKit/SwiftUI/MapKit in `Core/`, `App/`
- [x] run full test suite: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'`
- [x] run build: `xcodebuild -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16' build`

### Task 10: [Final] Update documentation
- [x] CLAUDE.md: short trap entry (speed/stops read filtered `trackLines`; plain mode under «Все точки»;
      speed tokens are non-adaptive next to `amber`)
- [x] write the "what changed / iOS-specific choices" summary at the top of this plan (as in the spike-filter plan)
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**:
- replay a real race track (or record a walk with stops) on a device: bands look plausible, a standing phone
  shows «stop» color and one stop marker, not many small ones
- tune constants on real data: window (60–120 s), long step (3 min), stop threshold (1 km/h), band limits;
  if one noisy fix splits a long stop in two, consider merging stops < 60 s / < 50 m apart
- check color contrast on the offline topo tiles (green forest, brown contours, blue water) and on the Apple
  map in light and dark mode; check that КП pins stay distinct from the speed colors
- performance with a full-day track (~6k points): map stays smooth while panning and while recording

**Android port**:
- port `TrackSpeed` constants, algorithm and test cases 1:1 to `kolco24_app_v2`; preference key
  `track_color_by_speed` (default true) should match
