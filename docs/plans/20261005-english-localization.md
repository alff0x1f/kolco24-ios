# English localization (ru + en)

## Overview
- The app UI is Russian-only. Add English as a second language so the App Store reviewer (usually on an
  English device) sees an understandable UI. Russian stays the default and the source language.
- String Catalog with **semantic keys** (`marks.empty.title`) and generated Swift symbols
  (`Text(.marksEmptyTitle)`), so a key typo is a compile error.
- Language choice is the iOS per-app language (Settings → kolco24 → Language). The app adds a «Язык» row in
  Settings that opens it. No in-app picker.
- Out of scope: App Store Connect metadata, translating server data (race/team names, legend), in-app
  language picker, screenshots (the user checks the UI and makes screenshots).

## Context (from discovery)
- No localization today: no `.xcstrings`/`.lproj`. `kolco24.xcodeproj/project.pbxproj` has
  `developmentRegion = en`, `knownRegions = (en, Base)`, `LOCALIZATION_PREFERS_STRING_CATALOGS = YES`,
  `SWIFT_EMIT_LOC_STRINGS = YES` (`:459`, `:499`).
- ~390 Russian literals in 24 root views; ~150 in `Core/` and `App/`. Core files with real UI literals:
  `Core/Readiness/ReadinessChecklist`, `Core/Sync/RefreshErrorMessage`, `Core/Marks/ControlTime`,
  `Core/Track/TrackSpeed`, `Core/Time/SkewFormat`, `Core/Scan/ScanSession`, `Core/Team/TeamPickerLogic`,
  `Core/Admin/ProvisioningLogic`, `MemberProvisioningLogic`, `AdminSession`, `Core/Nfc/ChipRecord`,
  `Core/Util/PluralRu`. Other Core files only have Cyrillic comments.
- `App/`: AppModel, MarksModel, ScanModel (NFC alert text `:611`, `:613`), PhotoModel, UploadModel,
  SettingsModel (byte units `["Б","КБ","МБ","ГБ"]` + decimal comma `:242`, `:257`), MapModel,
  ProvisioningModel, MemberProvisioningModel.
- Platform adapters with user-visible text: `Nfc/NfcChipScanner.swift:76` («Приложите чип КП», CoreNFC sheet),
  `Map/TrackMapView.swift:384` («Стоянка …»), `:488` («КП N · …»). `Audio/` and the rest are logs.
- Permission strings: `INFOPLIST_KEY_NFCReaderUsageDescription`, `…NSCameraUsageDescription`,
  `…NSLocalNetworkUsageDescription`, `…NSLocationWhenInUseUsageDescription` in both build configs (Russian).
- `Core/Util/PluralRu.swift`: `pluralRu`, `pointsWord`/`pointsLabel` (GPS points), `segmentsWord`,
  `relativeTimeRu` («только что / N мин назад / N ч назад», used at `App/UploadModel.swift:330`).
  Callers build phrases from word fragments: `CheckChipView:96,114`, `ScanSheet:452-453`, `LegendView:174`,
  `ProvisioningView:147`, `CheckMemberChipView:82`, `MarksView:1033`, `TeamView:461,603-604,638`,
  `SettingsView:196`, `Map/TrackMapView:488`, `Core/Team/TeamPickerLogic:74,80`.
- Pre-existing bug: `TrackMapView.swift:488` shows the КП cost via `pointsLabel` (GPS «точка») → «3 точки»
  instead of «3 балла». Fixed in Task 7 by the whole-phrase key.
- Dates: Core formatters use `en_US_POSIX` numeric formats — no change. `App/AppModel.swift:738` uses
  `.formatted(.dateTime.hour().minute())` → "2:30 PM" in en; acceptable.
- Opening iOS Settings: `URL(string: "app-settings:")` via `@Environment(\.openURL)` — `MarksView.swift:422`,
  `PhotoCaptureView.swift:224`.
- Tests: ~117 test files contain Cyrillic, ~295 `#expect` lines assert Russian text; the scheme is not shared.
- Toolchain: Xcode 26.4, iOS 18 target, Swift 5. Verified with `xcstringstool` on a prototype catalog:
  symbol generation works for keys with `extractionState: manual`; generated code is
  `import Foundation` + `extension LocalizedStringResource` (fine for Core); compile produces
  `ru.lproj`/`en.lproj` with `Localizable.strings` + `.stringsdict`; a key without en is absent from en.lproj.

## Development Approach
- **testing approach**: Regular (code first, then tests in the same task)
- complete each task fully before moving to the next; small focused changes; one commit per task
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task; for view-only tasks
  (8–10, 12) the gate is build + catalog tests (views have no unit tests per CLAUDE.md)
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- work on a new branch from `main` (never commit to `main`); the current `docs/release-checklist` branch has
  unrelated uncommitted changes — leave them alone
- unconverted strings stay Russian literals, so the app works after every task

## Testing Strategy
- **unit tests**: the suite runs in Russian (shared scheme Test action language = ru), so the existing
  Russian assertions stay valid and prove the ru values are unchanged.
- **English checks**: Core/App code resolves with the current locale (ru in tests), so en assertions do **not**
  run Core code paths in en. They resolve the symbol directly: `var r = LocalizedStringResource.key(...);
  r.locale = Locale(identifier: "en"); String(localized: r)` (verified, incl. plurals). Use them for
  placeholder order and plural forms. No locale-injection seams in Core.
- **catalog tests** (Task 1): ru guard, en/ru key sets equal and non-empty, keys match the semantic pattern.
- no UI/e2e test target; the user checks views manually.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Solution Overview
- **Catalogs**: `kolco24/Localizable.xcstrings` (`sourceLanguage: "ru"`, every key with
  `extractionState: manual` and explicit ru + en values) and `kolco24/InfoPlist.xcstrings` (en values of the
  4 permission strings; ru stays in `INFOPLIST_KEY_*`). `kolco24/` is a synchronized group.
- **Project**: `developmentRegion = ru`, `knownRegions = (ru, en, Base)`,
  `STRING_CATALOG_GENERATE_SYMBOLS = YES`, `SWIFT_EMIT_LOC_STRINGS = NO` (both app configs). Extraction off:
  all keys are manual, so Xcode must not sync ~390 unconverted literals and previews into the catalog. No
  `Text(verbatim:)` sweep needed.
- **Keys**: `<screen>.<element>[.<state>]`, lowerCamel segments; shared strings under `common.*`.
  `readiness.team.missing` → `.readinessTeamMissing`; keys with placeholders → functions
  (`.readinessChipsBound(bound, total)`, unlabelled `Int` args).
- **Views**: `Text(.key)`, `Button(.key)`, `Label(.key, systemImage:)`, `.navigationTitle(.key)`, `alert`,
  `confirmationDialog`, `TextField`, `Section` (all have `LocalizedStringResource` overloads on iOS 16+).
  Own components keep `String` parameters; call sites pass `String(localized: .key)`.
- **Core/App**: UI text → `String(localized: .key)` (Foundation only). Models keep returning `String`.
  Not translated: logs, file names, protocol/stored values, GPX, server data, `#Preview` sample data.
- **Plurals**: each plural key is a **whole phrase containing `%lld`** (a variant without the number does not
  compile): `"Осталось %lld чипов"`, `"%lld баллов"`. ru one/few/many/other, en one/other. Bare-word labels
  (`TeamView:603-604` metric captions) become separate non-plural keys or put the number into the string.
  `PluralRu.swift` and its tests are deleted at the end of Task 7.
- **Settings**: «Язык» row with value `settings.language.current` (ru «Русский», en "English" — the catalog
  itself reports the active language), tap opens `app-settings:`.

## Technical Details
- Glossary:

  | ru | en |
  |---|---|
  | КП | CP |
  | отметка / взятие КП | punch |
  | Отметки (tab) | Punches |
  | Легенда | Legend |
  | Карта | Map |
  | Команда | Team |
  | чип | chip |
  | браслет | wristband |
  | соревнование / гонка | race |
  | балл | point |
  | точка (GPS) | track point |
  | сегмент | segment |
  | стоянка | stop |
  | КВ (контрольное время) | time limit |
  | трек | track |
  | судья / судейская отметка | judge / judge scan |

- Placeholders: `%lld` for `Int` (convert `Int64` explicitly, e.g. `SkewFormat.swift:23`), `%@` for `String`;
  positional `%1$lld`/`%2$lld` when en word order differs. Key names must be descriptive — args are unlabelled.
- English test helper `kolco24Tests/Support/EnglishLocalization.swift`:
  `func en(_ r: LocalizedStringResource) -> String` + `ru(_:)` (set `r.locale`; verified in Task 1).
- Catalog test reads compiled `ru.lproj`/`en.lproj` `Localizable.strings` + `.stringsdict` from
  `Bundle.main` and compares key sets.
- Key pattern: `^[a-z][a-zA-Z]*(\.[a-zA-Z]+)+$` (first segment may be lowerCamel: `controlTime.*`; **no digits** —
  the symbol generator uppercases the letter after a digit: `a11y` → `A11Y`).
- ⚠️ `%lld` is formatted with the locale: ru 1500 → «1 500» (grouping). Fine for counts; identifiers (team/bib/chip numbers, codes, years) go as `%@` with `String(n)`.
- Byte sizes: replace the hand-made units/decimal comma in `SettingsModel` with
  `ByteCountFormatter`/`.formatted(.byteCount(style: .file))` (locale-aware), or keep the hand-made one with
  keyed units — pick in Task 6 based on how tests pin today's output.
- Device languages other than ru/en (kk, uk, be…) without ru in the preferred list resolve to **en**, not ru
  (checked on macOS Foundation; confirm on iOS simulator in Task 14). Decision: see ⚠️ in Task 14.
- The per-app «Language» page in iOS Settings shows only when the device has more than one preferred
  language. The row must not promise more: its footer says that the language is chosen in iOS Settings.

## What Goes Where
- **Implementation Steps**: code, catalogs, project settings, tests, CLAUDE.md, release.md.
- **Post-Completion**: manual check of ru/en UI on device, App Store Connect English metadata.

## Implementation Steps

### Task 1: Localization infrastructure

**Files:**
- Modify: `kolco24.xcodeproj/project.pbxproj`
- Create: `kolco24.xcodeproj/xcshareddata/xcschemes/kolco24.xcscheme`
- Create: `kolco24/Localizable.xcstrings`
- Create: `kolco24Tests/Support/EnglishLocalization.swift`
- Create: `kolco24Tests/LocalizationTests.swift`

- [x] create a branch `feat/english-localization` from `main`
- [x] set `developmentRegion = ru`, `knownRegions = (ru, en, Base)`; in both app configs add
      `STRING_CATALOG_GENERATE_SYMBOLS = YES` and set `SWIFT_EMIT_LOC_STRINGS = NO`
- [x] share the `kolco24` scheme (hand-written from pbxproj ids, both testables like the auto scheme); Test action `language = "ru"`, `region = "RU"`
- [x] add `Localizable.xcstrings` (`sourceLanguage: "ru"`) with one key `common.cancel`
      (`extractionState: manual`, ru «Отмена», en "Cancel"); confirm the symbol compiles and `en.lproj` is in
      the bundle
- [x] add the `en(_:)` test helper
- [x] write `LocalizationTests`: guard `Bundle.main.preferredLocalizations.first == "ru"` with a message
      pointing at the shared scheme; ru/en key sets equal and every value non-empty; keys match the pattern;
      `common.cancel` → «Отмена» / "Cancel"
- [x] build + full test suite green (also via `xcodebuild test`, confirming the scheme language reaches the
      hosted test process)

### Task 2: Permission strings in English

**Files:**
- Create: `kolco24/InfoPlist.xcstrings`
- Modify: `kolco24Tests/InfoPlistTests.swift`

- [x] add `InfoPlist.xcstrings` with en values for the 4 usage descriptions (ru entries added by Xcode from
      `INFOPLIST_KEY_*` are fine)
- [x] keep ru in `INFOPLIST_KEY_*`; confirm the merged plist builds
- [x] ➕ ru values duplicated in `InfoPlist.xcstrings`: a key with no ru value compiles into `ru.lproj` as the key itself (prompt would read «NSCameraUsageDescription»); test `russianUsageDescriptionsMatchInfoPlist` keeps them equal to `INFOPLIST_KEY_*`
- [x] extend `InfoPlistTests`: `Bundle.main.path(forResource: "InfoPlist", ofType: "strings",
      inDirectory: nil, forLocalization: "en")` has all 4 keys, non-empty
- [x] run tests - must pass before next task

### Task 3: Readiness checklist and refresh errors

**Files:**
- Modify: `kolco24/Core/Readiness/ReadinessChecklist.swift`, `kolco24/Core/Sync/RefreshErrorMessage.swift`
- Modify: `kolco24/Localizable.xcstrings`, matching tests

- [x] move title/detail strings to `readiness.*` keys (`readiness.chips.bound` with 2 args)
- [x] move refresh error texts to `refresh.error.*`
- [x] existing Russian tests stay green unchanged
- [x] add en symbol assertions for 2–3 keys incl. one with args
- [x] run tests - must pass before next task

### Task 4: Control time, track speed, clock skew

**Files:**
- Modify: `kolco24/Core/Marks/ControlTime.swift`, `kolco24/Core/Track/TrackSpeed.swift`,
  `kolco24/Core/Time/SkewFormat.swift`
- Modify: `kolco24/Localizable.xcstrings`, matching tests

- [x] classify every Cyrillic literal: UI text vs log/stored value
- [x] move UI text to `controlTime.*`, `track.speed.*`, `clock.skew.*` keys (`Int64` → `Int` where needed)
- [x] existing Russian tests green; add en symbol assertions (1–2 per file)
- [x] run tests - must pass before next task

### Task 5: Scan, team picker, provisioning, admin, chip logic

**Files:**
- Modify: `kolco24/Core/Scan/ScanSession.swift`, `Core/Team/TeamPickerLogic.swift`,
  `Core/Admin/ProvisioningLogic.swift`, `MemberProvisioningLogic.swift`, `AdminSession.swift`,
  `Core/Nfc/ChipRecord.swift`
- Modify: `kolco24/Localizable.xcstrings`, matching tests

- [x] classify literals; leave stored/protocol values untouched
- [x] move UI text to `scan.*`, `teamPicker.*`, `provisioning.*`, `admin.*`, `chip.*` keys
- [x] `TeamPickerLogic:74,80` («Категория X · N человек»): plural `teamPicker.people` + `teamPicker.categoryPeople`
      (`%1$@ · %2$@`); `peopleWord` removed, its tests now check the plural key
- [x] existing Russian tests green; add en symbol assertions per area (incl. the plural phrase)
- [x] run tests - must pass before next task

### Task 6: App models and platform adapters

**Files:**
- Modify: `kolco24/App/AppModel.swift`, `MarksModel.swift`, `ScanModel.swift`, `PhotoModel.swift`,
  `UploadModel.swift`, `SettingsModel.swift`, `MapModel.swift`, `ProvisioningModel.swift`,
  `MemberProvisioningModel.swift`
- Modify: `kolco24/Nfc/NfcChipScanner.swift` (`:76` alert message)
- Modify: `kolco24/Localizable.xcstrings`, matching tests (incl. `kolco24Tests/App/SettingsModelTests.swift`)

- [x] move status/error texts to keys (reuse Core keys and `common.*` where text is the same)
- [x] NFC sheet texts (`NfcChipScanner:76`, `ScanModel:611,613`) → `nfc.alert.*`
- [x] `relativeTimeRu` → `relativeTimeLabel` in `Core/Util/RelativeTime.swift` with keys `upload.lastSent.*`
      («только что», «%lld мин назад», «%lld ч назад»); tests moved to `RelativeTimeTests`
- [x] byte-size formatting in `SettingsModel`: units keyed `common.bytes.*`, fraction via
      `.formatted(.number.precision(.fractionLength(1)).grouping(.never))`; `SettingsModelTests` pass unchanged
- [x] existing Russian tests green; add en symbol assertions for upload/scan statuses and relative time
- [x] run tests - must pass before next task

### Task 7: Plural phrases in views, remove PluralRu

**Files:**
- Modify: `kolco24/CheckChipView.swift`, `ScanSheet.swift`, `LegendView.swift`, `ProvisioningView.swift`,
  `CheckMemberChipView.swift`, `MarksView.swift`, `TeamView.swift`, `SettingsView.swift`,
  `kolco24/Map/TrackMapView.swift`
- Delete: `kolco24/Core/Util/PluralRu.swift` and its tests
- Modify: `kolco24/Localizable.xcstrings`

- [x] whole-phrase plural keys with `%lld`: `common.points.count` («%lld баллов»), `checkChip.othersOnCp`,
      `scan.remainingChips` (verb + noun in one string), `wristband.pool.count`, `team.chips.unbound`,
      `track.points.count` (GPS), `track.segments.count`, `legend.totalScore`
- [x] `TeamView:603-604` metric captions → fixed `track.metric.points`/`track.metric.segments` («Точки»/«Сегменты»;
      ru captions no longer decline by count — small visible change)
- [x] ➕ also converted the non-plural strings in the same expressions: `scan.timer.*` (ScanSheet status line),
      `wristband.pool.notSynced`, `marks.photoReview.*`, `map.stop.title`, `map.cp.callout`; `capitalizedFirst` removed
- [x] `TrackMapView:488` КП callout uses `common.points.count` (fixes «точки» → «балла»);
      `:384` «Стоянка …» → `map.stop.*`
- [x] replace every `pluralRu`/`pointsLabel`/`pointsWord`/`segmentsWord` call; delete `PluralRu.swift` and
      its tests (grep shows no callers left)
- [x] write tests: ru forms for 1/2/5/11/21, en forms for 1/2, for 2–3 plural keys
- [x] run tests - must pass before next task

### Task 8: Views — Marks tab, scan sheet, photo

**Files:**
- Modify: `kolco24/MarksView.swift`, `ScanSheet.swift`, `PhotoCaptureView.swift`, `PhotoLightboxView.swift`,
  `PhotoNumberPickerView.swift`, `EmptyStates.swift`, `ClockBanners.swift`, `ConfettiOverlay.swift`,
  `SharedComponents.swift`, `ContentView.swift` (tab titles)
- Modify: `kolco24/Localizable.xcstrings`

- [x] convert literals to symbols; `String` params of own components get `String(localized: .key)` at call
      sites
- [x] `#Preview` sample data stays as is
- [x] ➕ `accessibilityLabel`/`Hint` have no `LocalizedStringResource` overload → `Text(.key)`
- [x] ➕ fixed `ScanSheet` cost «N баллов» without declension → `common.points.count`
- [x] build + run tests (catalog tests are the gate) - must pass before next task

### Task 9: Views — Legend and Map tabs

**Files:**
- Modify: `kolco24/LegendView.swift`, `MapTabView.swift`, `kolco24/Map/TrackMapView.swift` (remaining text)
- Modify: `kolco24/Localizable.xcstrings`

- [x] convert literals; server data (legend text, race name) passes through unchanged
- [x] build + run tests - must pass before next task

### Task 10: Views — Team tab, Settings, Upload, team picker; «Язык» row

**Files:**
- Modify: `kolco24/TeamView.swift`, `SettingsView.swift`, `UploadView.swift`, `TeamPickerView.swift`,
  `TeamConfirmSheet.swift`, `CompPickerView.swift`, `BindChipSheet.swift`
- Modify: `kolco24/Localizable.xcstrings`, `kolco24Tests/LocalizationTests.swift`

- [x] convert literals
- [x] add the «Язык» row: title `settings.language`, value `settings.language.current`, footer
      `settings.language.footer` (chosen in iOS Settings); tap opens `app-settings:` via `openURL`
- [x] test: `settings.language.current` → «Русский» in ru, "English" in en
- [x] ➕ `monthDay` month abbreviations → `compPicker.month.*`; GPX track name fallback uses `teamPicker.teamNumber`
- [x] build + run tests - must pass before next task

### Task 11: Views — admin flows

**Files:**
- Modify: `kolco24/AdminFlowView.swift`, `ProvisioningView.swift`, `MemberProvisioningView.swift`,
  `JudgeScanView.swift`, `CheckChipView.swift`, `CheckMemberChipView.swift`
- Modify: `kolco24/Localizable.xcstrings`

- [x] convert literals
- [x] build + run tests - must pass before next task
- [x] ➕ `TextField`/`SecureField(LocalizedStringResource)` is iOS 26+ → `String(localized:)` title

### Task 12: Cyrillic literal check and English proofread

**Files:**
- Create: `kolco24Tests/CyrillicLiteralTests.swift`
- Modify: `kolco24/Localizable.xcstrings`

- [ ] test reads sources via `#filePath` (root views, `Core/`, `App/`, `Nfc/`, `Map/`): no Cyrillic inside
      string literals; skip comments, `log.`/`Self.log.` lines and `#if DEBUG … #endif` / `#Preview` blocks;
      explicit allow-list for any remaining exception
- [ ] test passes on the tree
- [ ] proofread all en values against the glossary; fix length on tight places (tiles, badges, buttons)
- [ ] run tests - must pass before next task

### Task 13: Verify acceptance criteria
- [ ] every user-visible string is in the catalog with ru + en (catalog test + Cyrillic test)
- [ ] permission prompts are English on an en simulator
- [ ] ru UI unchanged (Russian test suite green)
- [ ] ⚠️ check on a kk (or uk) simulator which language the app picks; report to the user and record the
      decision here (accept English, or mitigate)
- [ ] run full test suite: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'`

### Task 14: [Final] Update documentation
- [ ] CLAUDE.md: Hard invariants — no Cyrillic UI literals (`CyrillicLiteralTests`); idioms — semantic keys +
      generated symbols, `extractionState: manual`, extraction off, plural keys are whole phrases, tests run in
      ru via the shared scheme (`-testLanguage ru -testRegion RU` as CLI fallback)
- [ ] `docs/release.md`: review Notes mention the English UI follows the device language; do not promise
      in-app switching
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**:
- run on device/simulator in ru and en; walk the reviewer path from `docs/release.md` (demo race, photo punch,
  legend, map, organizer login); check text truncation on tiles and buttons in en
- «Язык» row → iOS Settings: language page appears only with 2+ preferred device languages

**External system updates**:
- App Store Connect: optional English metadata localization (description, keywords)
- optionally rename server demo data («Демо» team) to English for the reviewer
