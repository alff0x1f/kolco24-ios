# CLAUDE.md

Guidance for Claude Code (claude.ai/code) in this repository.

Detailed per-stage design notes live in `docs/plans/completed/*.md` (android-port stages 1–11 + the map tab).
**Before deep work in a layer, read its stage doc** — this file is only the map and the traps.

## Build & Run

Prerequisite: `Config/Secrets.xcconfig` must exist (see next section) — build **and** tests fail without it
(tests are hosted in the app; an empty secret `fatalError`s the test run).

```bash
# Build (simulator)
xcodebuild -project kolco24.xcodeproj -scheme kolco24 \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run unit tests
xcodebuild test -project kolco24.xcodeproj -scheme kolco24 \
  -destination 'platform=iOS Simulator,name=iPhone 16'

# Run a single test class
xcodebuild test -project kolco24.xcodeproj -scheme kolco24 \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:kolco24Tests/SecretsTests
```

If the name-based destination is flaky, resolve a UDID via `xcrun simctl list devices available` and use
`-destination 'platform=iOS Simulator,id=<UDID>'`
(may also need `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).

## Secrets & project setup

- Fresh clone: `cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig` and fill in real values.
  `Config/App.xcconfig` does a non-optional `#include "Secrets.xcconfig"` (gitignored) — a deliberate hard gate.
- Value flow: xcconfig → `kolco24/Info.plist` (`Kolco24*` keys) → `enum Secrets` (`apiBaseURL`, `appKeyId`,
  `appSecret`, `localAPIBaseURL`; missing/empty → `fatalError`). Gotcha: `//` starts an xcconfig comment,
  so URLs use `https:/$()/...`.
- **ATS:** `NSAllowsLocalNetworking = YES` — cleartext HTTP only within the local network; the cloud API stays
  HTTPS-only.
- **Dependency:** GRDB.swift 7.x via SPM (Room analog), linked to the app target only; tests import it through
  the host app.
- **Project file gotchas:** `kolco24/` is a synchronized group (files auto-join the target); `Info.plist` is kept
  out of bundle resources via a `PBXFileSystemSynchronizedBuildFileExceptionSet` (`membershipExceptions`);
  `GENERATE_INFOPLIST_FILE = YES` (Xcode merges the partial plist — locked by `InfoPlistTests`).
  **Array-valued `INFOPLIST_KEY_*` build settings silently don't work** (e.g. `UIBackgroundModes`) — array keys
  go directly into `kolco24/Info.plist`; string keys (usage descriptions) go into both build configs as
  `INFOPLIST_KEY_<name>`.

## What the app is

SwiftUI iOS app (target iOS 18) for a rogaine/orienteering event; UI language is Russian. A staged port of the
Android app `kolco24_app_v2` (Kotlin/Room/OkHttp), functionally complete, plus an iOS-only offline map tab.
Four tabs: Отметки (`MarksView` — taken-КП grid + NFC/photo scan), Легенда (`LegendView`),
Карта (`MapTabView`), Команда (`TeamView` — roster/chip-binding/track/settings/upload entry points).

## Layout

- **`kolco24/` (root, flat)** — all SwiftUI views + `DesignTokens`, `SharedComponents`, `Secrets`.
- **`kolco24/Core/`** — pure-Foundation logic, grouped by concern (stages 1, 4–11, map): `Util` (HexBytes,
  PluralRu, RaceDates), `Nfc` (ChipRecord/K24 format, NfcUid), `Api` (HMAC signing), `Crypto` (LegendCrypto),
  `Scan` (ScanSession reducer, ChipScanning seams), `Team` (BindDecision, TeamPickerLogic), `Legend`,
  `Marks` (KpTake, PhotoMark, PhotoPaths, MarksDisplay), `Sync`, `Track` (Segments, TrackPoints, GpxExport,
  TrackEngine seam), `Upload`, `Time` (TrustedClock actor, ServerTimeSampler, SkewFormat), `Lease`,
  `Stores` (InstallId, ClockAnchorStore, ThemePreference, RaceLeaseStore, AdminTokenStore), `Admin`,
  `Map` (MBTiles math).
- **`kolco24/Model/`** — domain value types mirroring Room v5 (GRDB-free; conformances live in `Data/Records/`)
  (stages 1–2).
- **`kolco24/Data/`** (stages 2–3, 6–10, map) — `AppDatabase` (migration `v1` = Room v5 snapshot,
  `v2` = `races.mapUrl`; no FKs — Room parity, don't add), `Records/*+GRDB.swift`, `Stores/` (12 DAO-analog
  structs, SQL transcribed verbatim from Kotlin), `Repositories/` (4 sync repos + Mark/Track/JudgeScan upload
  drains, AdminAuthRepository), `Sync/SyncCoordinator`, `MBTilesReader`.
- **`kolco24/Net/`** (stage 3) — `ApiClient` (one pipeline replacing OkHttp interceptors: 6 signed `X-App-*`
  headers, optional Bearer outside the canonical string, 403-retry-once for GET only, POST **never** retries),
  `Dto/`, `URLSessionTransport` + `ApiClients` two-client factory (cloud/LAN).
- **`kolco24/App/`** (stages 4–11, map) — `@Observable @MainActor` models: `AppEnvironment` (composition root —
  construction order matters: leaseHolder → repos → syncCoordinator; adminSessionHolder → clients), `AppModel`
  (selection/refresh/upload triggers/clock status), per-tab models, `ScanModel`, `PhotoModel`, `TrackRecorder`,
  `UploadModel`, `SettingsModel`, `MapModel`, admin models.
- **Platform adapters** (stages 5, 7, 8, 10, map) — `Nfc/` (NfcChipScanner, MiFareTransport), `Location/`
  (provider + track engine), `Audio/` (ScanFeedbackPlayer), `Photo/` (storage, camera), `Keychain/`,
  `Map/` (MBTilesOverlay, TrackMapView, MapFileStorage).

Tests in `kolco24Tests/` mirror the Kotlin JVM tests where a Kotlin source exists; fresh Swift Testing suites
otherwise. Convention: real stores over `AppDatabase.makeInMemory()` + `FakeTransport`/`FakeChipScanner` — fake
only the network/NFC, never the DB. Platform adapters have no unit tests (device-only); their behavior is
covered through the pure seams. The hard gate for any change is the green local suite + build, not a live
server 200.

## Hard invariants (grep-enforced)

- `import GRDB` only under `Data/` (incl. `Data/Repositories/`, `MBTilesReader`); never in `Core/`, `Model/`,
  `Net/`, `App/`, `Map/`, `Photo/`.
- `Core/`, `Model/`, and all `App/` models are framework-free: only `Foundation`/`Observation`
  (no UIKit/SwiftUI/GRDB/CoreNFC/CoreLocation/AVFoundation/ImageIO/MapKit/Security).
- Each platform framework has exactly one home: `CoreNFC` → `Nfc/`; `CoreLocation` → `Location/`;
  `AVFoundation` → `Audio/` + `Photo/`; `ImageIO` → `Photo/`; `Security`/`SecItem*` → `Keychain/`;
  `MapKit` → `Map/`; UIKit-for-haptics → `Audio/` (plus the pre-existing UIKit in `DesignTokens.swift`).
- SwiftUI views live flat in the root `kolco24/` (plus `Photo/CameraPreviewView`, `Map/TrackMapView`).

## Recurring idioms (follow these when extending)

- **Injected-closure seams** for time/disk/system deps (the `TrustedClock` idiom): models take
  `wallNow`/`elapsedNow`/`writeFrame`/`persist` etc. as closures, making them testable without frameworks.
  Pure factory functions (`makeKpTakeMark`, `makePhotoMark`, `makeTrackPoints`, `makeJudgeScan`) take
  UUID + `TimeSample` **as parameters** for determinism.
- **Errors are values, never thrown**: `FetchResult`/`PostResult`/`RefreshResult` enums; decode/DB failures →
  fallback + log, never crash.
- **State holders**: `actor` where serialization suffices (TrustedClock, upload repos, SyncCoordinator);
  `NSLock`-guarded `final class` + seeded `.bufferingNewest(1)` `AsyncStream` where a **synchronous** read is
  required (`LeaseHolder`, `AdminSessionHolder` — pin-guards and `tokenProvider` must not actor-hop).
- **§6 rule**: DB/network writes triggered from UI run in unstructured `Task`s capturing the *stores/repos,
  not `self`* — dismissing a screen never aborts an in-flight write.
- **Rebind stale-guard**: every per-tab model, on team/race change, cancels the old observation task **and
  clears derived arrays** before re-subscribing (stale rows must never render).
- **Refresh flow** (server contract, exact): ETag conditional GET → on 200: delete other-origin ETag →
  `replaceAllForRace` → upsert new ETag — three transactions, **data before ETag**; pin-guard checked before
  the call *and re-checked after the 200*.
- **Upload drains**: `actor` + `inFlight` tryLock, shared generic `drainUploadLoop` (batch 500,
  `accepted ∩ batch` empty → `.error` anti-loop), Local then Cloud independent, outcome precedence
  `error > offline > ok > nil`.
- Stores/repos are `struct`s (no protocols/fakes for the DB); complex DAO SQL is transcribed verbatim from
  Kotlin for line-by-line checkability.

## Port traps (the ones that bite)

- **Hex from signed bytes**: Kotlin's `%02x` sign-extends on Swift `Int8` — all hex goes through
  `Core/Util/HexBytes` over `UInt8`/`Data`.
- **Signed requests**: paths carry a trailing slash (it's in the canonical string) — except the photo-frame
  path `/photo/<frameId>` which has none; the POST body is serialized **once** (same bytes hashed and sent);
  POST never retries (403 is auth-vs-skew-ambiguous).
- **DTO encoding**: hand-written `encode(to:)` reproduces kotlinx.serialization — no-default nullables as
  explicit JSON `null`, Kotlin-default fields omitted. Rename traps: `wall_ms ← takenAt`,
  `trusted_ms ← trustedTakenAt`, `elapsed_at ← elapsedRealtimeAt`, `cp_nfc_uid ← cpUid`. `/marks/` duplicates
  `source_install_id` in-body; `/track/` and judge scans have their own field quirks — check the stage doc +
  Kotlin before touching a DTO.
- **Units**: `start_time`/`finish_time` are **ms**; `X-App-Ts` is unix **seconds**.
- **Blocking semaphore bridges** (`MiFareTransport.transceive`, `AppModel.syncSample`) are sanctioned **only**
  on the dedicated NFC delegate/read queue — never main or the cooperative pool (deadlock).
- **Lease `nowMs` is wall clock** (`Date()`), not `TrustedClock` — `isRacePinned` must be synchronous;
  the relative-TTL path is skew-immune anyway.
- **MBTiles TMS y-flip** (`tile_row = 2^z − 1 − y`) lives only in `Core/Map/MBTiles.tmsRow`.
- **`Category` collision**: in test files importing `Testing`+`Foundation`, qualify the domain type as
  `kolco24.Category`.
- `ClockAnchorStore` parse: trailing `|` with nil bootCount — use `components(separatedBy:)`
  (Swift `split` drops the empty segment).

## Design system (`DesignTokens.swift`)

- Adaptive light/dark palette via `Color(light:dark:)` / `Color(lightUI:darkUI:)`: `ink`, `sub`, `paper`,
  `brandRed`, `kolcoOrange`, `good`, `charcoal`, `charcoalHi`, `card`, `hairline`, `cardShadow`; `amber` is the
  only non-adaptive token. Theme switching is `preferredColorScheme` from `SettingsModel` — no custom
  persistence beyond `ThemePreference`.
- **Fixed-dark surfaces** stay dark in both themes: `DarkHeroBackground` (via the dark-valued `charcoal`
  tokens), `NFCTileView` (literal hex — a "chip card"), photo capture/lightbox. Don't "fix" their literals to
  adaptive tokens.
- Typography: `Font.mono(_:weight:)` = JetBrains Mono (bundled, declared under `UIAppFonts`).
  Spacing/radii in `enum DS`.
- Recurring motif: diagonal `Canvas` line hatch (`NFCTileView`, `PhotoTileView`, `DarkHeroBackground`).
- Removed features stay removed: no `isRecent` green ring on tiles.

## Known facts, not bugs

- Backend endpoints **not yet deployed**: `POST /app/race/<id>/marks/`, the binary photo-frame endpoint,
  `POST …/judge_scans/`. Live runs show perpetual «ошибка»/pending — the designed self-heal (flags stay 0,
  same build re-sends when deployed). `POST …/track/` **is** deployed.
- The prod server always answers `data_source: "cloud"` → the LAN pin never engages outside a race-LAN
  deployment (`MOBILE_DATA_SOURCE=local`).
- Force-quit kills track recording (Android `START_NOT_STICKY` parity).
- `LiveServerSmokeTests` is env-gated (`LIVE_API_SMOKE`) and skipped normally; `xcodebuild` doesn't forward
  shell env to the hosted simulator process.
- КП map pins come from the take's own GPS fix (`Mark.locLat/locLon`) — the server has no checkpoint
  coordinates; a take without a fix is deliberately not shown.
