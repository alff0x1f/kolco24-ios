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

**Entry point:** `kolco24App.swift` → `ContentView.swift` (3-tab `TabView`)

**Tabs:**
- `MarksView` — grid of taken checkpoints (КП), floating NFC/Photo CTA, scan sheet modal
- `LegendView` — filterable list of all checkpoints with progress strip
- `TeamView` — team members list with NFC chip binding status

**Design system (`DesignTokens.swift`):**
- Color palette named "A2 Grey v2" — use `Color.ink`, `Color.sub`, `Color.paper`, `Color.brandRed`, `Color.kolcoOrange`, `Color.good`, `Color.charcoal`, `Color.amber`
- Typography — `Font.mono(_:weight:)` wraps JetBrains Mono (must be bundled in app + declared in `Info.plist` under `UIAppFonts`)
- Spacing constants in `enum DS` — `DS.hPad`, `DS.cardRadius`, `DS.heroRadius`, `DS.ctaRadius`

**Shared components (`SharedComponents.swift`):**
- `CPBadge` — checkpoint number badge with red stripes
- `MetricView` — labelled metric with optional unit and warning state
- `VDivider`, `SectionHeader`, `GreenCheckCircle`
- `DarkHeroBackground` — reused by `TeamHeroView` and `TimerHeroView` (charcoal gradient + diagonal line pattern)

**Data:** All views currently use local mock data (structs with hardcoded arrays). No networking or persistence layer exists yet.

**NFC scan flow:** `FloatingCTAView` in `MarksView` presents `ScanSheet` as a `.sheet`. `ScanSheet` shows the CP waiting card, team chip slots grid, and `TimerHeroView`.
