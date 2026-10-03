# Admin actions gated by `admin_race_ids`

## Overview
- Server commit `df49883` (#277): `POST /app/login/` now returns `{token, expires_at, admin_race_ids}`.
  `admin_race_ids` = sorted ids of races where the user is `RaceAdmin(role=ADMIN)`; `[]` for a plain user,
  moderator or bare superuser. Login is open to every user (participants will sign in too).
- It is a UI hint only: every write (`tags/`, `member_tags/bind/`, `judge_scans/`) still checks
  `can_edit_race` on the server.
- Goal: the admin menu (`AdminFlowView`) shows its actions only when the selected race is in the list of a
  live session. Otherwise it shows «Нет прав администратора на эту гонку».

## Context (from discovery)
- `kolco24/Net/Dto/AuthDtos.swift` — `LoginResponse {token, expiresAt}`.
- `kolco24/Core/Admin/AdminSession.swift` — `AdminSession.loggedIn(email:token:expiresAt:)`,
  `adminRowSubtitle`, `combinedLoginOutcome`.
- `kolco24/Core/Admin/AdminSessionHolder.swift` — `seed(store:nowUtcIso:)`, `token`.
- `kolco24/Core/Stores/AdminTokenStore.swift` — `StoredAdminSession {token, email, expiresAt}` as one
  Keychain JSON item.
- `kolco24/Data/Repositories/AdminAuthRepository.swift` — `login` builds `.loggedIn` + `StoredAdminSession`.
- `kolco24/AdminFlowView.swift` — `AdminHomeView.menu`: 6 actions in 3 sections, gated today only by
  `appModel.selectedRaceId == nil`. `cloudSession`/`localSession` are `@State` fed by holder streams.
- `appModel.selectedRaceId: Int?`, `Race.id: Int`.
- `.loggedIn(` pattern matches (~18): `AdminFlowView`, `AdminSessionHolder`, `AdminSession`,
  `AdminAuthRepository`, tests `AdminSessionTests`, `AdminSessionHolderTests`, `AdminAuthRepositoryTests`,
  `ProvisioningModelTests`, `MemberProvisioningModelTests`.
- Login JSON fixture: `kolco24Tests/Net/ApiClientTests.swift:486`.
- Stage doc: `docs/plans/completed/20260929-lan-admin-session.md`.

## Development Approach
- **testing approach**: Regular (code first, then tests in the same task)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change
- work on a new branch from `main` (never commit to `main`)

## Testing Strategy
- **unit tests**: Swift Testing suites over pure seams; fake only network (`FakeTransport`), never the DB.
- No UI/e2e tests in the project; the menu branch is covered through the pure `isRaceAdmin`.

## Progress Tracking
- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Solution Overview
- The race list lives **inside the session**: `AdminSession.loggedIn(email:token:expiresAt:adminRaceIds:)`.
  Token and list change together and atomically, persist in the same Keychain item, and reach the menu
  through the existing holder streams (login / logout / 401 rebuild the menu with no new wiring).
- Cloud and LAN lists are **unioned**: pure `isRaceAdmin(raceId:cloud:local) -> Bool` in
  `Core/Admin/AdminSession.swift`. `.loggedOut` contributes nothing.
- **Missing list = no rights** (strict): an old LAN server without the field and an old Keychain item without
  the key both decode as `[]`. The session stays alive, actions are hidden; the admin re-logs in to refresh.
- All 6 actions are hidden without rights (including the offline checks).

## Technical Details
- `LoginResponse`: `let adminRaceIds: [Int]`, key `admin_race_ids`; custom `init(from:)` with
  `decodeIfPresent([Int].self, forKey: .adminRaceIds) ?? []`. Keep a memberwise init for tests.
- `StoredAdminSession`: `let adminRaceIds: [Int]`; custom `init(from:)` with `decodeIfPresent ?? []`;
  synthesized `encode(to:)` writes the key. `read()` empty-field checks unchanged (empty list is valid).
- `isRaceAdmin`:
  ```swift
  func isRaceAdmin(raceId: Int, cloud: AdminSession, local: AdminSession) -> Bool
  ```
  `true` if `raceId` is in the `adminRaceIds` of any `.loggedIn` session.
- Menu branches in `AdminHomeView.menu`:
  1. `selectedRaceId == nil` → current «Выберите команду…» hint (unchanged).
  2. race selected, `!isRaceAdmin` → section «Действия» with text «Нет прав администратора на эту гонку»
     (13pt, `Color.sub`, `Color.card` row background).
  3. otherwise → the 3 existing sections.
  Server status rows and «Выйти» always shown. An already-open action screen is not closed on 401 (YAGNI).

## What Goes Where
- **Implementation Steps**: code, tests, CLAUDE.md line.
- **Post-Completion**: manual check on device against prod and LAN server.

## Implementation Steps

### Task 1: Decode `admin_race_ids` in `LoginResponse`

**Files:**
- Modify: `kolco24/Net/Dto/AuthDtos.swift`
- Modify: `kolco24Tests/Net/DtoDecodingTests.swift`
- Modify: `kolco24Tests/Net/ApiClientTests.swift`
- Modify: `kolco24Tests/Data/Repositories/AdminAuthRepositoryTests.swift` (`LoginResponse(...)` at :47)

- [x] add `adminRaceIds: [Int]` + `CodingKeys` case; put custom `init(from:)` (`decodeIfPresent ?? []`) in an `extension LoginResponse` so the synthesized memberwise init survives; update file header comment
- [x] fix the only construction site `AdminAuthRepositoryTests.swift:47` (`LoginResponse(token:expiresAt:adminRaceIds: [])`)
- [x] update the login fixture at `ApiClientTests.swift:486` to include `"admin_race_ids":[3,7]` and assert it
- [x] write `DtoDecodingTests` case: field present → `[3, 7]`
- [x] write `DtoDecodingTests` case: field missing → `[]`
- [x] run tests - must pass before task 2

### Task 2: Persist `adminRaceIds` in `StoredAdminSession`

**Files:**
- Modify: `kolco24/Core/Stores/AdminTokenStore.swift`
- Modify: `kolco24Tests/Core/AdminTokenStoreTests.swift` (:33, 47, 61, 70, 113, 115, 117)
- Modify: `kolco24/Data/Repositories/AdminAuthRepository.swift` (:58)
- Modify: `kolco24Tests/Core/AdminSessionTests.swift` (`seedJson` helper :31)
- Modify: `kolco24Tests/Data/Repositories/AdminAuthRepositoryTests.swift` (:75, 128, 146, 159, 176, 262, 263)

- [x] add `adminRaceIds: [Int]` to `StoredAdminSession`; custom `init(from:)` (`decodeIfPresent ?? []`) in an extension so the memberwise init survives
- [x] `AdminAuthRepository.login` (:58) writes `response.adminRaceIds` into the stored session
- [x] give `seedJson` (`AdminSessionTests.swift:30`) an `adminRaceIds` parameter; fix remaining `StoredAdminSession(...)` sites (`grep -rn "StoredAdminSession(" kolco24 kolco24Tests`)
- [x] update comments: `AdminTokenStore.swift` header (:7 `{token, email, expiresAt}`) and `read()` doc (:36-38)
- [x] write test: write → read round-trip keeps ids
- [x] write test next to the raw-JSON fixture at `AdminTokenStoreTests.swift:105`: raw string `{token, email, expiresAt}` without the key reads as a session with `[]`
- [x] run tests - must pass before task 3

### Task 3: Carry ids in `AdminSession` + `isRaceAdmin`

**Files:**
- Modify: `kolco24/Core/Admin/AdminSession.swift`
- Modify: `kolco24/Core/Admin/AdminSessionHolder.swift`
- Modify: `kolco24/Data/Repositories/AdminAuthRepository.swift`
- Modify: `kolco24/AdminFlowView.swift` (pattern matches only)
- Modify: `kolco24Tests/Core/AdminSessionTests.swift`
- Modify: `kolco24Tests/Core/AdminSessionHolderTests.swift`
- Modify: `kolco24Tests/Data/Repositories/AdminAuthRepositoryTests.swift`
- Modify: `kolco24Tests/App/ProvisioningModelTests.swift`
- Modify: `kolco24Tests/App/MemberProvisioningModelTests.swift`

- [x] change case to `loggedIn(email:token:expiresAt:adminRaceIds:)`; fix binding patterns (ignore the field with `_`): `AdminSession.swift:88, 90, 92`, `AdminSessionHolder.swift:87`, `AdminFlowView.swift:242, 244, 400` (`:138` has no bindings — leave it)
- [x] add pure `isRaceAdmin(raceId:cloud:local)` in `AdminSession.swift`
- [x] `AdminSessionHolder.seed` (:152) copies `stored.adminRaceIds` into the session
- [x] `AdminAuthRepository.login` (:54) puts `response.adminRaceIds` into `.loggedIn`
- [x] mechanical fix of test constructions: `AdminSessionTests.swift:79, 120, 121`, `AdminSessionHolderTests.swift:15, 16`, `AdminAuthRepositoryTests.swift:73, 133`, `ProvisioningModelTests.swift:215`, `MemberProvisioningModelTests.swift:578` (check with `grep -rn "\.loggedIn(" kolco24 kolco24Tests`)
- [x] update doc comments: `AdminSession.swift:15-17` (`loggedIn`), `AdminAuthRepository.login` (:44)
- [x] write `AdminSessionTests` for `isRaceAdmin`: id in cloud only; id in LAN only; id in neither; both `.loggedOut` → `false`; empty lists → `false`
- [x] extend `seed_futureExpiry_isLoggedIn` (`AdminSessionTests.swift:76-80`) so `seedJson` and the expected session carry `[3, 7]`
- [x] extend `login_success_persistsAndUpdatesHolder` (`AdminAuthRepositoryTests.swift:60-77`): add `"admin_race_ids":[3,7]` to the :64 body and expect it at :73/:75; same for the LAN login fixture at :241
- [x] run tests - must pass before task 4

### Task 4: Gate admin menu actions by race rights

**Files:**
- Modify: `kolco24/AdminFlowView.swift`

- [x] add `canAdminSelectedRace` in `AdminHomeView` as only `selectedRaceId.map { isRaceAdmin(raceId: $0, cloud: cloudSession, local: localSession) } ?? false` (no extra logic in the view)
- [x] add the middle branch after the nil check: section «Действия» with «Нет прав администратора на эту гонку» (13pt, `Color.sub`, `Color.card`)
- [x] keep server status rows and «Выйти» in every branch
- [x] update the file header comments: `AdminFlowView.swift:9-11` and :18-19 (third branch)
- [x] tests: branch logic is covered by `isRaceAdmin` tests in Task 3 (views have no unit tests); build must succeed
- [x] run tests - must pass before task 5

### Task 5: Verify acceptance criteria
- [x] verify all requirements from Overview are implemented
- [x] verify edge cases: old Keychain item, LAN server without the field, cloud-only / LAN-only rights, no selected team
- [x] verify grep invariants: no new imports in `Core/` (Foundation only)
- [x] run full test suite: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'`
- [x] run build: `xcodebuild -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16' build`

### Task 6: [Final] Update documentation
- [x] CLAUDE.md «Admin sessions»: one line — `admin_race_ids` from login is a UI hint only; no list → `[]` (actions hidden); refreshed only by a new login
- [x] move this plan to `docs/plans/completed/`

## Post-Completion
*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Manual verification**:
- Device against prod: an admin of the selected race sees all actions; a plain account sees «Нет прав администратора на эту гонку».
- After the update, the existing admin session shows no actions until logout + login (the admin will be told).
- LAN server: deploy #277 there too, otherwise LAN-only login gives no rights.

**External system updates**:
- Android app may want the same gating (separate repo).
