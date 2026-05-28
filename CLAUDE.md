# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Build (simulator)
xcodebuild -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16' build

# Run unit tests
xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'

# Run a single test class
xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:kolco24Tests/kolco24Tests
```

Open `kolco24.xcodeproj` in Xcode to run on a simulator interactively.

## Architecture

SwiftUI iOS app for a rogaine/orienteering event. UI language is Russian. All source files live flat in `kolco24/`.

**Entry point:** `kolco24App.swift` → `ContentView.swift` (3-tab `TabView`, tinted `Color.kolcoOrange`, haptic on tab switch)

**Tabs:**
- `MarksView` — 4-column grid of taken checkpoints (КП), metrics card, floating NFC/Photo CTA, scan sheet modal
- `LegendView` — filterable list of all checkpoints with score progress strip (`.insetGrouped` List)
- `TeamView` — team hero card, member list with chip-binding status, misc settings rows

**Design system (`DesignTokens.swift`):**
- Color palette "A2 Grey v2": `Color.ink`, `Color.sub`, `Color.paper`, `Color.brandRed`, `Color.kolcoOrange`, `Color.good`, `Color.charcoal`, `Color.charcoalHi`, `Color.amber`
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

**`LegendCP.display`** formats as `"{cost}-{number}"` (e.g. `"4-07"`) for the legend list identifier column.
