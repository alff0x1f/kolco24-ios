# Separate cloud / LAN admin sessions

Port of Android `kolco24_app_v2` d021eaa (feat: lan admin session, #107).

## Problem

One admin session fed both clients: the cloud bearer went to the LAN client too — over cleartext,
and useless there (the LAN race server issues its own tokens via its own `/app/login/`).

## What changed

- **Two sessions.** `AppEnvironment.cloudAdminSession`/`cloudAdminAuth` (Keychain `kolco24.admin`, so
  old sessions survive) and `localAdminSession`/`localAdminAuth` (Keychain `kolco24.admin.local`).
  Each client gets the bearer of its own session only.
- **Bearer only where needed.** `ApiClient.post(..., adminAuth: true)` marks admin requests: `logout`,
  `bindTag`, `bindMemberTag`, `uploadJudgeScans`. Syncs and other uploads never carry the token.
  iOS deviation: Android tags only `logout` + `bindTag`; the server also gates `member_tags/bind/`
  and `judge_scans/` with `IsMobileUser`, so they are tagged here too.
- **LAN gate.** The LAN bearer is released only while a lease is active (`isLeaseActive`, wall clock
  like `isRacePinned`). Outside it the LAN address may be any network's device. `LeaseHolder` is now
  built by the factories before the clients (the LAN `tokenProvider` reads it).
- **Login.** First login (both logged out): cloud, plus LAN only in local mode. Lease re-checked at
  submit. Servers run in parallel; `combinedLoginOutcome` picks the shown error (a real answer beats
  «нет сети»). From admin home, «Войти» on a server row logs into only that server; the form closes
  when that session appears (not on a success callback).
- **Login vs logout race.** `AdminSessionHolder` has a login generation. `logout` bumps it, so a login
  response that lands later does not bring the session back (returns `.error`). Check-and-persist and
  clear run under the holder lock. `logout` with no session sends no request.
- **Provisioning routing.** `AppEnvironment.adminRoute(raceId:)` is resolved on every tap: LAN while
  the race is pinned, else cloud. No session there → inline «Нет входа на LAN-/cloud-сервер», no
  request. 401 clears only that server's session.
- **UI.** Admin home shows a Cloud and a LAN status row; Settings subtitle is `adminRowSubtitle`
  («email · только Cloud/LAN» for one server). Password field has a show/hide toggle.
- `lanActive` in the admin view is polled (appear, session change, `scenePhase == .active`) — the lease
  stream is single-consumer (owned by `SettingsModel`).
