# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

Prerequisite: `Config/Secrets.xcconfig` must exist (see next section) — both build and tests fail without it. Tests run hosted in the app, so an empty secret value crashes the test run with `fatalError` rather than a normal assertion failure.

```bash
# Build (simulator)
xcodebuild -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run unit tests
xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'

# Run a single test class
xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:kolco24Tests/SecretsTests
```

If the name-based destination is flaky, resolve a UDID via `xcrun simctl list devices available` and use `-destination 'platform=iOS Simulator,id=<UDID>'` (may also need `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`).

Open `kolco24.xcodeproj` in Xcode to run on a simulator interactively.

## Building from Scratch (Secrets)

A fresh clone does not build until secrets are in place:

```bash
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
# then fill in the real values
```

Without it the build fails with `could not find included file 'Secrets.xcconfig'` — a deliberate hard gate: the committed `Config/App.xcconfig` (base configuration of the app target) does a non-optional `#include "Secrets.xcconfig"`, and `Config/Secrets.xcconfig` is gitignored. Values flow xcconfig → `kolco24/Info.plist` (`Kolco24*` keys, merged with the generated plist) → `enum Secrets` in `kolco24/Secrets.swift` (`apiBaseURL`, `appKeyId`, `appSecret`, `localAPIBaseURL`; missing/empty value → `fatalError`). Gotcha: `//` starts a comment in xcconfig, so URLs use the `$()` trick (`https:/$()/...`).

**ATS:** `Info.plist` sets `NSAppTransportSecurity` → `NSAllowsLocalNetworking = YES` — cleartext HTTP is allowed only within the local network (any LAN/.local host, deliberately broader than Android's per-IP pin: `NSExceptionDomains` can't take IP addresses); the cloud API stays HTTPS-only.

**Dependencies:** GRDB.swift 7.x via SPM (SQLite, Room analog), linked to the app target only — tests import it through the host application.

**Project file gotcha:** `kolco24/` is a synchronized group (`PBXFileSystemSynchronizedRootGroup` — files dropped there auto-join the target), so `kolco24/Info.plist` is excluded via a `PBXFileSystemSynchronizedBuildFileExceptionSet` with `membershipExceptions = (Info.plist)` to keep it from being copied into the bundle as a resource; any file under `kolco24/` needing special target membership needs the same treatment. `GENERATE_INFOPLIST_FILE = YES` stays on — Xcode merges the partial plist with the generated keys (locked in by `InfoPlistTests`).

## Architecture

SwiftUI iOS app for a rogaine/orienteering event. UI language is Russian. The 8 UI/app files (`kolco24App`, `ContentView`, `MarksView`, `LegendView`, `TeamView`, `ScanSheet`, `SharedComponents`, `DesignTokens`) plus `Secrets` and `NFCReader` live flat in the root of `kolco24/`; the pure-logic port lives in the `kolco24/Core/` and `kolco24/Model/` subfolders (see "Pure logic layer" below).

**Entry point:** `kolco24App.swift` → `ContentView.swift` (3-tab `TabView`, tinted `Color.kolcoOrange`, haptic on tab switch)

**Tabs:**
- `MarksView` — 4-column grid of taken checkpoints (КП), metrics card, floating NFC/Photo CTA, scan sheet modal
- `LegendView` — filterable list of all checkpoints with score progress strip (`.insetGrouped` List)
- `TeamView` — team hero card, member list with chip-binding status, misc settings rows

**Design system (`DesignTokens.swift`):**
- Color palette "A2 Grey v2", **adaptive (light/dark)**: `Color.ink`, `Color.sub`, `Color.paper`, `Color.brandRed`, `Color.kolcoOrange`, `Color.good`, `Color.charcoal`, `Color.charcoalHi`. `Color.amber` is the only non-adaptive token (same in both themes via `Color(hex:)`).
- Surface/line/shadow tokens (replace former literals like `Color.white` / `Color.black.opacity(...)` in views): `Color.card`, `Color.hairline`, `Color.cardShadow`.
- Adaptive tokens are built with `Color(light:dark:)` (two hex strings) or `Color(lightUI:darkUI:)` (two `UIColor`s, for tokens carrying their own alpha — `hairline`, `cardShadow`). Both wrap `UIColor(dynamicProvider:)`, so the system switches the whole palette by `userInterfaceStyle` trait — there is no theme toggle, screen, or persistence. Dark hex values mirror the token table in `tmp/design_dark.html`.
- Typography — `Font.mono(_:weight:)` wraps JetBrains Mono (must be bundled + declared in `Info.plist` under `UIAppFonts`)
- Spacing/radius constants in `enum DS` — `DS.hPad` (16), `DS.cardRadius` (13), `DS.heroRadius` (18), `DS.ctaRadius` (16)

**Shared components (`SharedComponents.swift`):**
- `CPBadge` — checkpoint number badge with red top/bottom stripes; `number: "?"` renders faded
- `MetricView` — labelled metric with optional unit; `isWarning: true` renders value in `brandRed` with mono font
- `VDivider`, `SectionHeader`, `GreenCheckCircle`
- `DarkHeroBackground` — charcoal gradient + radial red accent + diagonal `Canvas` line pattern; used by `TeamHeroView` (in `TeamView.swift`) and `TimerHeroView` (in `ScanSheet.swift`)

**Data model pattern:** Each view file defines its own model structs at the top (`CheckpointTile`, `LegendCP`, `TeamMember`, `ChipSlot`). All data is local mock arrays — no shared state, networking, or persistence yet.

**NFC scan flow:** `FloatingCTAView` in `MarksView` presents `ScanSheet` as a `.sheet`. `ScanSheet` contains `CPWaitingCardView` (shows scanned КП badge), a 2-column `ChipSlotView` grid, and `TimerHeroView` (countdown circle + remaining scans).

**Recurring visual motif:** Diagonal `Canvas` line patterns appear in `NFCTileView`, `PhotoTileView`, and `DarkHeroBackground` — use the same approach when adding new tile/card types.

**Fixed-dark surfaces:** `DarkHeroBackground` (and its `TeamHeroView` / `TimerHeroView` users) and `NFCTileView` stay dark in *both* themes, so their white content reads correctly either way — but by different means. `DarkHeroBackground`'s gradient is built from the **adaptive** `charcoal`/`charcoalHi` tokens (both dark-valued in either theme, so it mirrors each design: `1D242D → 2A323C` light, `27313D → 171D25` dark); only its text/hatch content is theme-independent. `NFCTileView` is fully fixed via literal `Color(hex:)`, **not** adaptive tokens — a "chip card": a `#171D25 → #232A33` gradient with inset depth, a faint diagonal `Canvas` hatch, a three-arc contactless glyph (`#E6EAF0`), and a white mono number — no red reflective stripes (those belong to the light `CPBadge`, which is unchanged).

**Removed:** the `isRecent` field/feature (green ring overlay on tiles) no longer exists — don't reintroduce it.

**`LegendCP.display`** formats as `"{cost}-{number}"` (e.g. `"4-07"`) for the legend list identifier column.

## Pure logic layer (`Core/` + `Model/`)

Android-port stage 1 (see [`docs/plans/completed/20260708-android-port-stage1.md`](docs/plans/completed/20260708-android-port-stage1.md)) added the Android-free logic slab, ported 1:1 from `kolco24_app_v2` (Kotlin) together with its JVM tests mirrored into `kolco24Tests/Core/` (~160 Swift Testing cases). Layout is idiomatic Swift, **not** a mirror of Android packages — no `import UIKit`/`import SwiftUI` anywhere under `Core/`/`Model/`.

- **`kolco24/Core/`** — pure functions and value logic, grouped by concern:
  - `Util/` — `HexBytes` (hex codec, see hex trap below), `PluralRu` (Russian plurals + points/segments/relative-time words)
  - `Nfc/` — `NfcUid` (`normalizeNfcUid`), `ChipRecord` (`K24` chip format: `buildChipRecord`/`parseChipRecord`/`chipCodeHex`/`chipCodeFromHex`/`chipModelFromVersion` + `protocol NfcTransport` with header-last `writeRecord`/`readRecord`)
  - `Api/` — `Signing` (`sha256Hex`, `buildCanonical`, `sign` HMAC-SHA256, `EMPTY_BODY_SHA256`); the OkHttp interceptor stays behind for the stage-3 URLSession port
  - `Crypto/` — `LegendCrypto` (offline legend crypto: `bid` = sha256[:16], HKDF-SHA256 with an explicit 32-byte zero salt, AES-256-GCM with AAD)
  - `Scan/` — `ScanSession` (`reduce`/`classifyTag`, 20 s window state machine), `ScanFeedback`
  - `Team/` — `BindDecision` (`decideBind`, chip-to-member binding)
  - `Marks/` — `PhotoTarget` (`decidePhotoTarget`/`resolvePhotoCheckpoint`/`filterCheckpointsByQuery`)
  - `Track/` — `Segments` (`nextSegmentId`/`shouldLiveUpload`)
  - `Time/` — `TrustedClock` + `SystemClockProviders`
- **`kolco24/Model/`** — domain value types mirroring Room v5 (no `Entity` suffix; `Model/` itself stays free of `import GRDB` — the GRDB `FetchableRecord`/`PersistableRecord` conformances landed in stage 2 as `Data/Records/<Type>+GRDB.swift` extensions, keeping the value types Android-/GRDB-free). Stage 1 added `Checkpoint`, `Mark` (+ nested `MarkMemberSnapshot`), `MemberChipBinding`, and the `UnlockOutcome` enum (`revealed`/`identityOnly`/`unknown`/`failed`); stage 2 added the 10 remaining Room-v5 domain types: `Race`, `Category`, `Team` (+ nested `TeamMemberItem`), `SelectedTeam`, `Tag`, `MemberTag`, `LegendMeta`, `TrackPoint`, `JudgeScan`, `SyncMeta`. Kotlin sealed hierarchies became Swift `enum`s with associated values; data classes became `Equatable` structs; `ByteArray` → `Data`/`[UInt8]`; `Long` → `Int64`, `Float` → `Float`.

**`TrustedClock` (actor).** Ports `data/time/TrustedClock.kt` behavior 1:1 (server anchor pinned to a monotonic `elapsedRealtime`-style read, boot-session identity, monotonic-regression reboot detection, skew) but swaps the concurrency idiom: an `actor` (isolation serializes all reads/writes; callers `await`) replaces Kotlin's `AtomicReference` + `synchronized`. Instead of `StateFlow` it exposes an isolated `status: ClockStatus` (`noSync`/`ok`/`skewed(skewMs:)`, `SKEW_THRESHOLD_MS = 60_000`) plus a `nonisolated statusUpdates: AsyncStream<ClockStatus>` (`.bufferingNewest(1)`, equal values deduped by hand — the stage-11 skew banner is the consumer). Time sources are injected closures (`elapsedProvider`, `wallProvider`, `bootCountProvider`, `persist`/`persisted`), so the core is Android-/UI-free and async-unit-testable with fakes. Production providers live in `SystemClockProviders.swift`: elapsed = `mach_continuous_time()` in ms (keeps running while the device sleeps, unlike `systemUptime`/`CLOCK_UPTIME_RAW`), wall = `Date().timeIntervalSince1970 * 1000`, and `bootCount` is always `nil` (no iOS analog of `Settings.Global.BOOT_COUNT` — the ported logic treats `nil` as "no reboot evidence" and catches reboots via monotonic-clock regression against the saved anchor).

**KAT (known-answer test) vectors — byte-for-byte server interop.**
- `LegendCrypto`: `LegendCryptoTests` embeds a server-generated vector (`bid`, `wrapKey`, `iv`/`ct`, `aad`, plaintext) produced by a throwaway scratchpad script over the server reference `crypto.py`/`legend_crypto.py` (`src/apps/mobile/`) — importing `seal`/`derive_wrap_key`, reproducing the Django-ORM-bound `bid` and bundle-map one-liners. This proves HKDF (`salt=None` → 32 zero bytes), `bid`, and AAD interop. (The 4 corresponding Android tests are `@Ignore`d with `TODO(server-vector)`.)
- HMAC: the signing KAT is inline in `SigningTests` — `sign("test-secret-123", <canonical>)` = `cf1c254fb2eac6c7efde1cff6efe9553878370299cd60a42be4d2105a8072588`, cross-checked against a Python `hmac` one-liner.

**Main port trap — hex from signed bytes.** Kotlin smears `"%02x".format(byte)` / `b.toInt() and 0xFF` across files; `%02x` on a negative `Int8` in Swift sign-extends and corrupts the output. Everything therefore runs on `UInt8`/`Data`, and hex encode/decode goes through the single `Core/Util/HexBytes.swift` helper (nibble-indexed digit table — `v >> 4` / `v & 0x0F`) — it centralizes the hex logic Kotlin spreads across files as `%02x` / `b.toInt() and 0xFF` (the raw `& 0xFF` byte normalizations live in `ChipRecord.swift`).

## Data layer (`Data/`)

Android-port stage 2 (see [`docs/plans/completed/20260709-android-port-stage2.md`](docs/plans/completed/20260709-android-port-stage2.md)) added the GRDB persistence slab, ported 1:1 from `kolco24_app_v2`'s Room v5 (`data/db/`) with its DAO/converter tests mirrored into `kolco24Tests/Data/`. `import GRDB` lives **only** under `Data/`; `Core/`/`Model/` stay GRDB-free (grep-invariant, extending the stage-1 no-`UIKit`/`SwiftUI` rule — which also holds for `Data/`).

- **`kolco24/Data/AppDatabase.swift`** — wraps `any DatabaseWriter` + a `DatabaseMigrator` with a **single** migration `"v1"` = the finished Room v5 schema snapshot transcribed verbatim from `app/schemas/…/5.json` (the 1→5 migration history is *not* replayed — the iOS DB is born at v5). All 13 tables, 4 composite PKs, all indexes, **no SQL `DEFAULT`** (there are none in `5.json`'s `createSql` — Room defaults are Kotlin-side, applied in Swift initializers instead). No FKs anywhere (matches Room; do not add — it would change `replaceAllForRace` behavior). `makeShared()` = `DatabasePool` (WAL) at `kolco24.db` in Application Support; `makeInMemory()` = `DatabaseQueue()` for tests. Schema inventory is locked by `AppDatabaseSchemaTests` (replaces Android's `MigrationTest`).
- **`kolco24/Data/Records/*+GRDB.swift`** (13 files) — GRDB `FetchableRecord`/`PersistableRecord` conformances as **extensions** on the `Model/` types (hand-written `init(row:)` + `encode(to:)`, `databaseTableName` = Room table name), so `Model/` stays import-GRDB-free. JSON columns (`teams.members`, `marks.present`, `marks.presentDetails`) are coded here (analog of Room `TypeConverter`): `JSONEncoder(.sortedKeys)`, unknown keys ignored on decode, decode error → fallback (`[]` / `nil`) + log, never crash. `TeamMemberItem` uses `CodingKeys` with `number_in_team`.
- **`kolco24/Data/Stores/*.swift`** — 12 store **structs** (one per Android DAO — `struct`, not `protocol`: real stores over an in-memory DB serve both tests and the stage-3 repositories; no fakes). Kotlin `suspend` → `async throws` via GRDB `read`/`write`; Kotlin `Flow` → `ValueObservation.tracking{…}.values(in:)` (reactivity is wired now; stage 4 only subscribes). **SQL transcribed verbatim** rule: complex queries (team `startNumber` sort, `COALESCE(trustedTakenAt, takenAt)`, CASE upload-count aggregates) are ported as literal SQL strings — the goal is line-by-line checkability against the Kotlin DAO, not a pretty DSL. Shared DAO helper types (`UploadCounts`, `TrackScope`, `PhotoFrameRow`) live in `UploadTypes.swift`. Richest store is `MarkStore` (transactional `addMember` read-modify-write, `attachLocation`/`attachPhotos`, version-guarded `…IfUnchanged` family, photo/frame upload-drain aggregates); `CheckpointStore.replaceAllForRace` is **preserve-reveal** (snapshot revealed rows → wipe+insert server rows → re-apply plaintext, all in one transaction).

**Key-value stores** (only the two with a stage-2/3 consumer). Same idiom as `TrustedClock`: a pure core with injected `load`/`save` closures + a thin `fromUserDefaults` adapter over `UserDefaults.standard` (no separate suites — iOS has no Android backup-rules split; a stale anchor restored from backup is caught by `TrustedClock`'s monotonic-regression check).
- **`kolco24/Core/Stores/InstallId.swift`** — get-or-create UUID, key `install_id` (feeds stage-3 `X-Install-Id` header + `judge_scans.sourceInstallId`).
- **`kolco24/Core/Time/ClockAnchorStore.swift`** — key `anchor`, delimited format `"serverEpochMs|anchorElapsedMs|capturedWallMs|bootCount?"` 1:1 from Kotlin. Port trap: with `bootCount == nil` the string ends in `|`; parse via `components(separatedBy:)` and require exactly 4 components (Swift `split` drops the trailing empty segment).
- **`TrustedClock.makeDefault()`** (in `SystemClockProviders.swift`) — factory wiring the system providers to `ClockAnchorStore`'s `persist`/`persisted`. Actual app wiring lands in stages 3–4.

**Deferred** (explicitly out of stage 2, no code yet): `ThemePreference`/`TrackProfilePreference` (stages 8–9), `AdminTokenStore`/Keychain (stage 10), `RaceLeaseStore` (stage 9).
