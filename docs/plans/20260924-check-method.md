# Per-tag check method (offline / cloud / local)

## Overview
- Every `CheckpointTag` already has a server field `check_method`. Today the app stores it (`Tag.checkMethod`)
  and only shows it on the admin check-chip screen; scoring ignores it.
- New rule ("proof at the КП, the server decides"):
  - `offline`: no change. A complete take counts.
  - `cloud`: the take counts only if the **cloud** server accepted the mark **while the scan sheet was open**.
  - `local`: the same, but through the **local (LAN)** server.
- A later background upload still sends the mark, but it does **not** confirm it. The server makes the final
  call. The app shows an honest local status: unconfirmed takes stay visible, but they are not counted.
- Server values are renamed to `offline` / `cloud` / `local` (today: `offline` / `online` / `local_server`,
  and all live data is `offline`). The server change is in a separate repo (see Post-Completion).
- iOS-only feature: the Android app does not handle `check_method`, so there is no Kotlin source to port.

## Context (from discovery)
- Tag → take path: `Data/Repositories/LegendRepository.swift:149` (`unlock` loads the `Tag`) →
  `Model/UnlockOutcome.swift` → `Core/Scan/ScanSession.swift:170` (`classifyTag`, `.kp` event at :96) →
  `App/ScanModel.swift` (`process`, `handleCompletionCheck`) → `Core/Marks/KpTake.swift` (`makeKpTakeMark`).
- "Taken" today = `mark.complete`: `Core/Marks/MarkMetrics.swift` (`takenPoints`, `takenPointCount`,
  `totalScore`), `Core/Marks/MarksDisplay.swift` (`marksToTiles`, `photoReviewSummary`, `hiddenTakenTokens`).
- Upload: `Data/Repositories/MarkUploadRepository.swift` (`flushScope`, `drainUploadLoop`, GPS-aware
  mark setters), `Data/Stores/MarkStore.swift` (`uploaded*` flags reset on every change,
  version-guarded setters), `Core/Upload/UploadModels.swift` (`UploadTarget`).
- Schema: `Data/AppDatabase.swift` (migrations `v1`–`v3`).
- UI: `ScanSheet.swift`, `MarksView.swift` (photo-review notice at :471), `PhotoLightboxView.swift`,
  `App/MarksModel.swift` (`photoReview` at :282), `App/AppModel.swift:389` (`makeScanModel`).
- Known fact: `POST /app/race/<id>/marks/` is not deployed on prod yet, so `cloud` КП can't be confirmed in
  prod until it is. This is fine while all tags are `offline`.

## Development Approach
- **testing approach**: Regular (code first, then tests in the same task)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - write unit tests for new and modified functions
  - cover both success and error scenarios
  - update existing tests if behavior changes
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change
- maintain backward compatibility: old rows and unknown values behave as `offline`
- work on a branch (e.g. `feat/check-method`), never commit to `main`

## Testing Strategy
- **unit tests**: required for every task. Repo convention: real stores over `AppDatabase.makeInMemory()`,
  fake only network/NFC (`FakeTransport`, `FakeChipScanner`).
- **e2e tests**: the project has no UI e2e tests. View changes (`ScanSheet`, `MarksView`) are covered through
  model/pure-function tests plus manual checks (see Post-Completion).
- `Category` collision: in test files importing `Testing`+`Foundation`, write `kolco24.Category`.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Solution Overview
- **Snapshot on the mark.** At scan time the scanned tag's method is copied into the new mark
  (`marks.checkMethod`). A later legend change does not affect old takes. Different tags on one КП with
  different methods just work.
- **Separate confirmation field.** `marks.confirmedAt` is set only by the confirm call from the open scan
  sheet. It is never reset by `addMember`/`upsert`, unlike `uploaded*`. The background drain never sets it.
- **One pure rule** `isCounted(mark)` replaces `complete` in all scoring and "taken" derivations.
- **Confirm in the sheet.** For a `cloud`/`local` take, when the roster is complete the sheet stops the NFC
  scanner (the CoreNFC sheet is modal, so buttons behind it can't be tapped), sends this one mark to the
  required server, retries for up to 20 s, then shows success (auto-close + fanfare) or failure
  (Повторить / Закрыть).
- **Marks tab.** Unconfirmed takes keep their tile (dimmed + `icloud.slash` icon) and get a notice card. They
  are not counted in СУММА/ВЗЯТО, and the legend does not mark them as taken.
- The mark DTO wire contract does **not** change: the server already knows each tag's method.

**Deliberately unchanged (still use `complete`, not `isCounted`)**
- `decidePhotoTarget` (`Core/Marks/PhotoTarget.swift:41`): a photo may attach to a recent unconfirmed take as
  evidence. Judges see it.
- `controlTimeState` (`Core/Marks/ControlTime.swift:46`): start/finish КП are not expected to be cloud/local.
- `MapModel.pins`: pins show where the team was, not the score.
- Photo takes (`method == "photo"`) are `offline`, so a photo of a cloud КП skips the confirmation. This is
  intended: photo-only КП already go to judge review (`photoReviewSummary`), and judges make the call.

## Technical Details

**Schema: migration `v4`**
```sql
ALTER TABLE marks ADD COLUMN checkMethod TEXT NOT NULL DEFAULT 'offline';
ALTER TABLE marks ADD COLUMN confirmedAt INTEGER;  -- wall ms; NULL = not confirmed
```

**Core rule (`Core/Marks/CheckMethod.swift`)**
```swift
enum CheckMethod: Equatable {
    case offline, cloud, local
    init(_ raw: String)          // "cloud" → .cloud, "local" → .local, anything else → .offline
    var uploadTarget: UploadTarget? // .cloud → .cloud, .local → .local, .offline → nil
}

func isCounted(_ m: Mark) -> Bool {
    m.complete && (CheckMethod(m.checkMethod) == .offline || m.confirmedAt != nil)
}

func isUnconfirmed(_ m: Mark) -> Bool {
    m.complete && CheckMethod(m.checkMethod) != .offline && m.confirmedAt == nil
}
```

**`unconfirmedTokens(_ marks: [Mark]) -> [String]`** — marks come newest-first (like `hiddenTakenTokens`):
filter `isUnconfirmed`, skip КП that have any `isCounted` take, dedupe by `checkpointId` (keep newest), reverse
to oldest-first. Token = `"<cost>-<NN>"` with the live `costOf`, or just `"NN"` for cost 0 (the same format as
`photoReviewSummary`).

**Confirm call (`MarkUploadRepository`)**
```swift
func confirm(markId: String, target: UploadTarget, now: Int64) async -> UploadResultKind
```
1. Load the mark by id (missing → `.error`).
2. POST a one-mark batch through `uploadMarks` on the `cloud` or `local` client
   (the same `MarkDto`, `sourceInstallId`).
3. `id ∈ accepted` → `markStore.setConfirmedAt(id:, at: now)` + the existing GPS-aware `uploaded*` setter for
   that target → `.ok`. Otherwise map with `uploadResultKind` (`.offline` / `.error`); a 200 without the id →
   `.error`.
4. It does **not** take the `inFlight` tryLock (a running drain must never skip the confirm). A repeat POST of
   an already-uploaded id is safe (the server de-duplicates by id).

**ScanModel confirm state**
```swift
enum ConfirmState: Equatable { case sending(target: UploadTarget, attempt: Int), confirmed, failed(target: UploadTarget) }
private(set) var confirmState: ConfirmState?
```
- Injected seams (all with prod defaults so existing `ScanModel(...)` call sites compile):
  `confirmMark: @Sendable (String, UploadTarget) async -> UploadResultKind`,
  `confirmTimeoutMs` (default `CONFIRM_TIMEOUT_MS = 20_000`), `confirmRetryMs` (default `3_000`).
  The deadline is measured with the existing injected `elapsedNowMs`, not wall time, so tests are
  deterministic with tiny ms values. Real upper bound = timeout + one request timeout (cloud client: 10 s,
  `URLSessionTransport.swift:71`).
- The take keeps `takeCheckMethod: CheckMethod` from the `.kp` event.
- **Member writes are tracked.** Today `addMember` Tasks are fire-and-forget (`ScanModel.swift:456-462`) and
  may run in any order. Keep them in `@ObservationIgnored var memberWrites: [Task<Void, Never>]` (reset on a new
  take). The confirm waits for `takePersistTask` **and all** `memberWrites`, so the POSTed row has the full
  `present[]`.
- **No fanfare / «Готово!» before confirmation.** Today the completing transition in `applyFeedback`
  (`ScanModel.swift:522-524`) calls `scheduleFanfare()` + `beginCompletionHold()` (sets `completed`). For a
  cloud/local take: `completed` still flips (the roster is complete), but `scheduleFanfare()` is skipped and
  moves to the `.confirmed` transition. The sheet hides «Готово!» while `confirmState` is `.sending`/`.failed`.
- `handleCompletionCheck`: offline → today's path. Otherwise, **enter confirm mode**: set `.sending(target, 1)`
  **first**, then stop the scanner and the window timer, then start `confirmTask`.
- **Stream end must not close the sheet.** `scanner.stop()` finishes the readings stream, and the stream
  consumer calls `requestClose()` unconditionally (`ScanModel.swift:259`). Guard it:
  `if confirmState == nil { requestClose() }` (the confirm flow closes the sheet itself on success).
- **Readings are ignored in confirm mode.** Readings already forwarded before the stop still drain through
  `process()`. `process()` returns early when `confirmState != nil`, so a late `.kp` can't open a new take or
  cancel the hold.
- `confirmTask` loop: `for attempt in 1...` { set `.sending(target, attempt)`; run **one** confirm call in its
  own unstructured `Task` that captures the repository closure, not `self` (§6: an in-flight POST is never
  aborted by closing the sheet; if the server accepts it, `confirmedAt` is still written); await its value;
  `.ok` → break; check `Task.isCancelled`; deadline passed → `.failed`; sleep `confirmRetryMs`; check
  `Task.isCancelled` again }. `confirmTask` holds `self` weakly.
  - success → `.confirmed` → fanfare, `didComplete = true`, success hold, then `requestClose()`.
  - timeout → `.failed(target)`. No auto-close, no `didComplete`, no fanfare.
- `retryConfirm()` (Повторить): only from `.failed`; starts a new 20 s cycle. The scanner is not restarted.
- `stop()` and `deinit` cancel `confirmTask` (mirror the other tasks in `deinit`, `ScanModel.swift:190-207`).
  No new attempts start after that. A POST already in flight finishes by itself (see above).

**Sheet texts**
- sending: «Отправка на сервер…» (cloud) / «Отправка на локальный сервер…» (local), plus «попытка N».
- failed: «Нет связи — КП не подтверждён», buttons «Повторить» / «Закрыть».

**Marks tab**
- `MarkTile.unconfirmed: Bool` (from `isUnconfirmed`). Tile: ~45% opacity + an `icloud.slash` corner icon.
  Lightbox: «не подтверждён сервером».
- Notice: «Не подтверждены сервером (N): <tokensLabel> — отметьтесь на КП ещё раз при наличии связи».
  Hidden when the list is empty.

## What Goes Where
- **Implementation Steps**: iOS code, tests, docs in this repo.
- **Post-Completion**: server `choices` rename (separate repo), manual device checks.

## Implementation Steps

### Task 1: Mark fields + migration v4 + store support

**Files:**
- Modify: `kolco24/Model/Mark.swift`
- Modify: `kolco24/Data/Records/Mark+GRDB.swift`
- Modify: `kolco24/Data/AppDatabase.swift`
- Modify: `kolco24/Data/Stores/MarkStore.swift`
- Modify: `kolco24Tests/Data/AppDatabaseSchemaTests.swift`
- Modify: `kolco24Tests/Data/MarkStoreTests.swift`

- [ ] add `checkMethod: String = "offline"` and `confirmedAt: Int64? = nil` as the **last** defaulted params
      of `Mark.init` (~98 test call sites + `UploadView.swift:207-212` keep compiling)
- [ ] map both columns in `Mark+GRDB` (decode + encode)
- [ ] register migration `v4` (the two `ALTER TABLE` statements); no FKs
- [ ] `MarkStore.addMember` (:84-116, the only row rebuild) carries `checkMethod` and `confirmedAt` through
      unchanged; add `setConfirmedAt(id:at:)` as a column-scoped `UPDATE` that does **not** bump `updatedAt`
      and is not version-guarded (confirmation is a fact). Whole-row `upsert` callers only insert fresh ids.
- [ ] tests: update `migrationRunsOnEmptyDatabase` (`AppDatabaseSchemaTests.swift:216`, now
      `["v1","v2","v3","v4"]`); add a `v3 → v4` test in the v2/v3 pattern: old rows →
      `checkMethod == "offline"`, `confirmedAt == nil`
- [ ] tests: `addMember` resets `uploaded*` but keeps `checkMethod` and `confirmedAt`; `setConfirmedAt`
      round-trip; `setConfirmedAt` on a missing id is a no-op
- [ ] run tests - must pass before next task

### Task 2: CheckMethod + isCounted in metrics and display

**Files:**
- Create: `kolco24/Core/Marks/CheckMethod.swift`
- Modify: `kolco24/Core/Marks/MarkMetrics.swift`
- Modify: `kolco24/Core/Marks/MarksDisplay.swift`
- Create: `kolco24Tests/Core/CheckMethodTests.swift`
- Modify: `kolco24Tests/Core/MarkMetricsTests.swift`
- Modify: `kolco24Tests/Core/MarksDisplayTests.swift`

- [ ] create `CheckMethod` (parse, `uploadTarget`), `isCounted`, `isUnconfirmed`
- [ ] `takenPoints`, `takenPointCount` (both overloads), `totalScore` (both), `photoReviewSummary`,
      `hiddenTakenTokens`: use `isCounted` where they use `complete`
- [ ] `marksToTiles`: keep showing all `complete` takes; add `MarkTile.unconfirmed` (default false)
- [ ] add `unconfirmedTokens(_:costOf:)` per Technical Details
- [ ] tests: parse `"offline"`, `"cloud"`, `"local"`, `"nfc"` (unknown → offline); `uploadTarget` mapping;
      the `isCounted` / `isUnconfirmed` matrix (complete × method × confirmedAt)
- [ ] tests: metrics exclude an unconfirmed cloud take, include a confirmed one, offline unchanged;
      `marksToTiles` sets `unconfirmed` and keeps the tile
- [ ] tests: `unconfirmedTokens` dedupe per КП, excludes КП with a counted take, oldest-first, cost-0 token
- [ ] existing `MarksDisplay*` / `MarkMetrics` tests stay green
- [ ] run tests - must pass before next task

### Task 3: Tag method flows into the take

**Files:**
- Modify: `kolco24/Model/UnlockOutcome.swift`
- Modify: `kolco24/Data/Repositories/LegendRepository.swift`
- Modify: `kolco24/Core/Scan/ScanSession.swift`
- Modify: `kolco24/Core/Marks/KpTake.swift`
- Modify: `kolco24/App/ScanModel.swift` (pass-through only)
- Modify: `kolco24Tests/Data/Repositories/LegendRepositoryTests.swift` (incl. `.kp`/outcome literals ~:405, :432)
- Modify: `kolco24Tests/Core/ScanTagDecisionTests.swift` (`classifyTag` tests, :42-85)
- Modify: `kolco24Tests/Core/ScanSessionTests.swift` (:16, :170, :199), `kolco24Tests/Core/ScanFeedbackTests.swift`
  (:15, :33), `kolco24Tests/Core/KpTakeTests.swift`, `kolco24Tests/App/ScanModelTests.swift`

- [ ] `UnlockOutcome.revealed` / `.identityOnly` gain `checkMethod: String`; `unlock` fills it from the local
      `tag` at both constructor sites (`LegendRepository.swift:155` and :176-178; `LegendCrypto.UnlockResult`
      has no method). `ScanModel.checkpointsMap` (:485) matches bare cases and needs no change.
- [ ] `ScanEvent.kp` gains `checkMethod`; update the matches in `reduce` (`ScanSession.swift:122`) and
      `ScanModel.process` (:380). `ScanFeedback.swift:32` uses a bare `.kp` and compiles unchanged.
      Admin/judge flows have their own `.kpChip` enums and are not touched.
- [ ] `makeKpTakeMark` takes `checkMethod` and writes it; `makePhotoMark` stays `"offline"` (model default)
- [ ] `ScanModel.process`: pass it to `makeKpTakeMark` and keep `takeCheckMethod` in the take state
- [ ] tests: `unlock` returns the tag's method for revealed and identity-only tags
- [ ] tests: `classifyTag` carries the method; `makeKpTakeMark` writes it; a `ScanModel` take of a
      `"cloud"` tag persists `checkMethod == "cloud"`
- [ ] run tests - must pass before next task

### Task 4: MarkUploadRepository.confirm

**Files:**
- Modify: `kolco24/Data/Repositories/MarkUploadRepository.swift`
- Modify: `kolco24Tests/Data/Repositories/MarkUploadRepositoryTests.swift`

- [ ] add `confirm(markId:target:now:)` per Technical Details (no `inFlight` lock; load via the existing
      `MarkStore.getById(_:)`, `MarkStore.swift:41`)
- [ ] on accept: `setConfirmedAt` + the GPS-aware `uploaded*` setter for that target
- [ ] tests: cloud → only the cloud transport is called, `confirmedAt` + `uploadedCloud` set, `.ok`
- [ ] tests: local → only the local transport is called, `confirmedAt` + `uploadedLocal` set
- [ ] tests: offline, 5xx, and 200 without the id → `confirmedAt == nil`, correct result kind;
      missing mark → `.error`
- [ ] tests: confirm while a drain is in flight (`GatedTransport`) still POSTs — assert 2 requests are
      recorded while the drain is gated (the gated path is the same `/marks/`, so only the request count is
      checkable)
- [ ] run tests - must pass before next task

### Task 5: ScanModel confirm state machine

**Files:**
- Modify: `kolco24/App/ScanModel.swift`
- Modify: `kolco24/App/AppModel.swift` (`makeScanModel` wires `confirmMark` from `env.markUploadRepository`
  + a `TrustedClock`/wall `now`)
- Modify: `kolco24Tests/App/ScanModelTests.swift`

- [ ] add `ConfirmState`, `confirmState`, the injected `confirmMark` / `confirmTimeoutMs` / `confirmRetryMs`
      (defaulted init params; ScanSheet preview and `ScanModelTests` :131, :556 keep compiling)
- [ ] track `memberWrites`; the confirm waits for `takePersistTask` + all member writes
- [ ] `applyFeedback`: skip `scheduleFanfare()` on the completing transition for a cloud/local take
- [ ] `handleCompletionCheck`: offline → unchanged; cloud/local → set `.sending` first, stop the scanner and
      timer, run `confirmTask` (one confirm call per unstructured `Task`, `Task.isCancelled` after every call
      and sleep, deadline via `elapsedNowMs`, weak `self`)
- [ ] guard the stream-end `requestClose()` (`ScanModel.swift:259`) with `confirmState == nil`;
      `process()` returns early when `confirmState != nil`
- [ ] success → `.confirmed` → fanfare, `didComplete`, hold, close; timeout → `.failed`, no close, no fanfare
- [ ] `retryConfirm()`; `stop()` and `deinit` cancel `confirmTask`
- [ ] add a fanfare counter to `RecordingFeedback` in `ScanModelTests`
- [ ] tests: offline take auto-closes with fanfare as before (regression)
- [ ] tests: cloud take, confirm fails once then `.ok` → `.sending(…,1)` → `.sending(…,2)` → `.confirmed`,
      `didComplete`, close requested, scanner stopped, fanfare called only after `.confirmed`
- [ ] tests: the scanner stop (its stream finishes) during `.sending` does **not** set `closeRequested`
- [ ] tests: always failing → `.failed` after the timeout, no close, no `didComplete`, no fanfare;
      `retryConfirm` starts a new cycle and can succeed
- [ ] tests: a `.kp` reading for another КП delivered after confirm starts opens no new take
- [ ] tests: the confirm call sees the full `present[]` when member writes finish out of order
- [ ] tests: `stop()` during `.sending` → no more confirm calls; confirm is called with the right target
      (`.local` for a local tag)
- [ ] run tests - must pass before next task

### Task 6: ScanSheet confirm UI

**Files:**
- Modify: `kolco24/ScanSheet.swift`

- [ ] extract a `ConfirmStatusView(state:onRetry:onClose:)` subview
- [ ] under the КП header, show the sending text (per target) + spinner + «попытка N»
- [ ] on `.failed`: «Нет связи — КП не подтверждён» + «Повторить» (`retryConfirm`) and «Закрыть» buttons
- [ ] hide «Готово!» (:233/:257) and disable the «Готово» button (:202-209) while `.sending`/`.failed`
- [ ] `#Preview`s of `ConfirmStatusView` for `.sending` and `.failed` (next to the existing ones at :491-507)
- [ ] no new unit tests (view only; logic covered in Task 5); build must pass
- [ ] run tests - must pass before next task

### Task 7: Marks tab tile, notice, lightbox

**Files:**
- Modify: `kolco24/App/MarksModel.swift`
- Modify: `kolco24/MarksView.swift`
- Modify: `kolco24/PhotoLightboxView.swift`
- Modify: `kolco24Tests/App/MarksModelTests.swift`
- Modify: `kolco24Tests/App/LegendModelTests.swift`

- [ ] `MarksModel.unconfirmedTokens` (live `costOf`), next to `photoReview`
- [ ] tile: dimmed + `icloud.slash` corner icon when `tile.unconfirmed`
- [ ] notice card in the photo-review style, hidden when empty
- [ ] lightbox caption «не подтверждён сервером» for unconfirmed tiles
- [ ] tests: `MarksModel` — an unconfirmed cloud take shows in `tiles`, not in the score/count, and
      appears in `unconfirmedTokens`; after `setConfirmedAt` it counts and leaves the notice
- [ ] tests: `LegendModel` — an unconfirmed take does not mark the КП as taken; a confirmed one does
- [ ] run tests - must pass before next task

### Task 8: Verify acceptance criteria
- [ ] verify all requirements from Overview are implemented
- [ ] verify edge cases: retake confirms the КП and drops it from the notice; legend method change doesn't
      affect old takes; unknown method string = offline; photo takes = offline
- [ ] grep invariants: no `import GRDB` outside `Data/`; `Core/` and `App/` only `Foundation`/`Observation`
- [ ] run full test suite: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'`
- [ ] run the build

### Task 9: [Final] Update documentation
- [ ] CLAUDE.md (keep compact): migration list gets `v4` = `marks.checkMethod` + `marks.confirmedAt`;
      one line on `isCounted` replacing `complete` and on "confirmedAt is set only from the open scan sheet"
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Server change (separate repo `~/src/kolco24`)**
- `src/website/models/checkpoint.py:75`: change `CheckpointTag.check_method` choices to
  `("offline", "Офлайн")`, `("cloud", "Облако")`, `("local", "Локальный сервер")`; default stays `offline`.
- Add a Django migration that only changes the choices (all existing data is `offline`, nothing to convert).
- Update the server tests that set `check_method = "online"` (`src/apps/mobile/tests.py` ~:1052, :1091) to
  `"cloud"`.
- Deploy `POST /app/race/<id>/marks/` before any tag is switched to `cloud`.

**Manual verification on a device**
- Offline КП: scan → auto-close + confetti as before.
- Cloud КП with network: «Отправка на сервер…» → confirmed → auto-close; the tile is normal; the score counts.
- Cloud КП in airplane mode: after ~20 s «Нет связи»; Повторить after turning the network on → confirmed.
- Close on failure: the tile is dimmed with the icon, the notice lists the КП, the score and legend don't
  count it; a later background upload does not change this.
- Local КП on the race LAN (`MOBILE_DATA_SOURCE=local` server).
