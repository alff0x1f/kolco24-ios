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

## Network & sync layer (`Net/` + `Data/Repositories/`)

Android-port stage 3 (see [`docs/plans/completed/20260709-android-port-stage3.md`](docs/plans/completed/20260709-android-port-stage3.md)) added the URLSession network slab + 4 sync repositories, ported from `kolco24_app_v2`'s `data/api/` + `data/*Repository.kt` with ~148 JVM tests mirrored into `kolco24Tests/Net/` and `kolco24Tests/Data/Repositories/`. **Not a 1:1 port** — URLSession has no OkHttp interceptor chain, so what Android splits across `AppSignatureInterceptor` + `ServerTimeInterceptor` collapses into one explicit pipeline inside `ApiClient`. The *behavioral* server contract (canonical strings, "data → then ETag" order, retry/RTT rules) is transcribed exactly — it's the spec locked by the mirrored tests. Consumers land later: stage 4 wires repositories to UI, stage 6 reuses the generic `post` pipeline for uploads, stage 9 substitutes a lease into the `isRacePinned` seam.

- **`kolco24/Net/ApiClient.swift`** — a `struct` whose deps are values + closures (the `TrustedClock` idiom), not injected services. One `send(...)` pipeline replaces both interceptors, in OkHttp-chain order: build `URLRequest` → sign with **6** `X-App-*` headers → `transport` with RTT timing → `ServerTimeSampler` → `await onServerTime?` → **403-retry-once** for GET/HEAD only when `ts` changed. Six headers: `X-App-Key-Id`, `X-App-Sig` (lower-hex HMAC of the `buildCanonical` string, stage-1 `Core/Api/Signing`), `X-App-Ts` (unix **seconds**, re-read on retry), `X-Install-Id`, **`X-App-Platform: ios`** (Android sends `android`), `X-App-Version` (`CFBundleShortVersionString`). `Authorization: Bearer` is added when `tokenProvider() != nil` but is **not** in the canonical string. `nowSeconds`/`onServerTime` are `async` closures with **inline `await`** (both are `TrustedClock`-actor calls) — the retry decision reads `nowSeconds()` *strictly after* `onServerTime` re-anchors, or 403 self-healing goes flaky (fire-and-forget `Task {}` would read the stale `ts`). Generic `post` serializes the body **once** to `Data` — the same bytes are hashed into the signature and sent — and **never retries** (403 is auth-vs-skew-ambiguous, replay unsafe); GET/empty body → `EMPTY_BODY_SHA256`. Endpoints are conditional GETs (`If-None-Match` verbatim with quotes): `fetchRaces`/`fetchTeams`/`fetchLegend`/`fetchMemberTags` (all ETag/304) + `fetchSync` (no ETag, lease manifest — stage 9 consumer). Paths carry a **trailing slash** (it's in the signed canonical path); `baseURL` is stored without one.
- **`kolco24/Core/Time/ServerTimeSampler.swift`** — pure port of `ServerTimeInterceptor.kt`: RFC-1123 `Date` header + `requestElapsedMs`/`responseElapsedMs` → `ServerTimeSample(serverEpochMs, anchorElapsedMs)?`. Server time is pinned to **RTT midpoint** (`requestElapsedMs + rtt/2`, overflow-safe form); missing/malformed `Date`, negative RTT, or RTT over the Kotlin limit → `nil` (no-op). `wallNow`/`bootNow` for `TrustedClock.onServerTime` are **not** the sampler's job — the factory wiring closure captures them from `SystemClockProviders`.
- **`kolco24/Net/ApiResults.swift`** — `FetchResult<T>` (`.success(data:etag:)`/`.notModified`/`.forbidden`/`.error(code:)`) and `PostResult<T>` (`.success`/`.badRequest`/`.unauthorized`/`.forbidden`/`.conflict`/`.rateLimited`/`.offline`/`.error(code:)`) — Kotlin `sealed interface` → Swift `enum`, **errors are values, never thrown**. Kotlin asymmetry preserved: a transport `URLError` folds to `.error(nil)` on GET but `.offline` on POST (offline mid-race is an expected upload state). `code == nil` = `URLError` or a parse error.
- **`kolco24/Net/Dto/*.swift`** (5 files) — `Codable` wire-only types; `Model/` mapping is done by the repositories. Pointwise snake_case `CodingKeys`; unknown keys ignored (incl. `sync.versions`); forward-compat defaults via `decodeIfPresent ?? default` (`total_cost`/`scoring_count` → 0, `tags` → `[]`, `TeamDto.start_number` optional, `CheckpointDto.cost/description/enc/color` all optional — `enc != nil` is the locked sentinel). Traps: `start_time`/`finish_time` are **ms** (`Int64`, 0 = none), `paid_people: Double`, legend tag key is `checkpoint_id`, `EncDto{iv, ct}` are base64.
- **`kolco24/Net/URLSessionTransport.swift`** — the transport closure seam's prod impl (`ApiClient.transport` = its bound `send`): `URLSessionConfiguration.ephemeral`, `urlCache = nil`, `.reloadIgnoringLocalCacheData` (the `Date` header — including on 304 — must be a live network value, it's what anchors the clock), single per-request timeout. Also the **two-client factory** `enum ApiClients` (port of `AppContainer.kt`): `makeCloud` (`Secrets.apiBaseURL`, 10 s, `onServerTime` → `TrustedClock`) and `makeLocal` (`Secrets.localAPIBaseURL`, 3 s for fast offline-fail off-Wi-Fi, **`onServerTime = nil`** — the LAN host never anchors trusted time). Both sign identically off the same `trustedClock.signingSeconds`. `makeDefaultPair()` builds the pair over a shared `TrustedClock.makeDefault()` + `InstallId.fromUserDefaults()`. App composition (full `AppContainer` analog) is stage 4.
- **`kolco24/Data/Repositories/*.swift`** (4 `struct`s over stage-2 stores) — shared **refresh flow**, a behaviorally exact port because it's the server contract: `(client, originKey)` picked by `SyncSource` → `syncMetaStore.getEtag` → conditional GET → on `.success`: **`deleteEtag` of the other origin (before the replace)** → `replaceAllForRace` → `upsert` new ETag (only if the server sent one). **Three separate transactions, "data → then ETag" order** is critical: a crash between them leaves fresh data with a stale/absent ETag (next refresh gets a harmless 200 and self-heals); the reverse order would pin a new ETag to old data forever. `RefreshResult` (`.updated`/`.notModified`/`.offline`/`.forbidden`/`.httpError(Int)`/`.skipped`) lives beside `RaceRepository`. **`isRacePinned: (Int) -> Bool` pin-guard seam** (currently always `false`; stage 9 substitutes a lease): checked before the network call **and re-checked after the 200** (source can flip mid-flight — a stale origin's response must not clobber the other's fresh rows). `sync_meta` keys: origin = base URL (cloud/LAN partition); resource = `"races"` / `"race/<id>/teams"` / `"race/<id>/legend"` / `"race/<id>/member_tags"`.
  - **`RaceRepository`** — the refresh-flow reference; **no pin-guard** (races are global, not race-scoped). `raceStore.replaceAll` (global).
  - **`TeamRepository`** — pin-guarded; `teamStore.replaceAllForRace` (one transaction over categories + teams). Maps `order` → `sortOrder`.
  - **`MemberTagsRepository`** — pin-guarded; plus a **synced marker** `sync_meta["race/<id>/member_tags/synced"] = "1"` written on **any** successful 200 (even with no server ETag) — distinguishes "pool empty but synced" from "never synced". `hasBeenSynced`/`observeHasBeenSynced` check either the ETag resource or the marker (over `SyncMetaStore.observeEtagsExist`); both the ETag and marker of the other origin are cleared before the replace.
  - **`LegendRepository`** — pin-guarded; persists to **three** stores: `checkpointStore.replaceAllForRace` (**preserve-reveal** — an offline-revealed CP is not re-locked), `tagStore.replaceAllForRace`, `legendMetaStore.upsert`. Maps `CheckpointDto` (`enc != nil` → locked, `color ?? ""`). Plus **`unlock(raceId:code:) async -> UnlockOutcome`** — the **offline** reveal (no network): `bid = LegendCrypto.bid(code)` → `tagStore.getByBid` → build `encById` from checkpoint rows → pure `LegendCrypto.unlock` (stage 1) → on `.revealed`, `checkpointStore.reveal` each CP. Outcomes `revealed`/`identityOnly`/`unknown`/`failed`.

**Grep-invariants (extends stages 1–2).** `import GRDB` only under `Data/` (repositories re-export GRDB's `AsyncValueObservation`, so `import GRDB` is expected in `Data/Repositories/`, not just `Data/`); no `import UIKit`/`SwiftUI` anywhere under `Core/`, `Model/`, `Data/`, `Net/`; `Net/` carries no `import GRDB` (`URLSessionTransport` imports only `Foundation`).

**Live smoke.** `kolco24Tests/Net/LiveServerSmokeTests.swift` is the only exercise of the real `URLSessionTransport` against the live server, gated by `@Suite(.enabled(if: … environment["LIVE_API_SMOKE"] != nil))`: a signed `GET /app/races/` through real `Secrets` must return `.success` (200, i.e. the server accepted the signature — not 403). It's skipped in the normal suite; run it with `LIVE_API_SMOKE=1` + `-only-testing:kolco24Tests/LiveServerSmokeTests`. Caveat: `xcodebuild` doesn't forward shell env into the hosted simulator test process, so a real live 200 requires setting the var in the scheme/test-plan — the green local suite is the hard gate, the live 200 is best-effort.
