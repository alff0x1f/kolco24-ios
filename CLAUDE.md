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

SwiftUI iOS app for a rogaine/orienteering event. UI language is Russian. All source files live flat in `kolco24/`.

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
