# Этап 9 портирования: LAN-режим и настройки

Детализация этапа 9 из [android-port.md](android-port.md). Этапы 0–8 выполнены: чистая логика, GRDB-слой, сеть/sync, `@Observable`-модели, NFC-скан, выгрузка взятий, фото-отметка и GPS-трек готовы и покрыты тестами. Этап 9 добавляет полный local-mode (lease на 12 ч + `SyncCoordinator` + переключение источников cloud/LAN) и экран настроек (тема, LAN-тумблер, очистка трека, скрытая отладка, версия).

## Overview

Пользователь на гонке включает тумблер «Локальный сервер (Wi-Fi гонки)» в настройках → приложение спрашивает LAN-сервер `GET /app/race/<id>/sync/`, и если тот отвечает `data_source: "local"` — «пришпиливает» (pin) гонку к LAN на срок lease (TTL сервера, иначе 12 ч по умолчанию): все рефреши races/teams/legend/member_tags идут с LAN-хоста, cloud-данные не могут затереть pinned-гонку (пин-гарды репозиториев этапа 3 наконец получают реальный lease). Пин снимается: истечением lease, серверным handback (`data_source: "cloud"` при очередной пробе), либо выключением тумблера. Потеря связи пин **не** снимает — кэш живёт, автосинки тихо фейлятся.

Экран настроек — шит из вкладки «Команда»: тема (Системная/Светлая/Тёмная), «Очистить трек», LAN-тумблер со статусом «Локальный режим до HH:mm», скрытая секция «Отладка» (10 тапов по «Версия»: сброс команды, очистка БД), «Версия».

**Ключевые решения брейншторма (адаптация под платформу, не 1в1 из Kotlin):**
- **`SyncCoordinator` — actor** (изоляция заменяет котлиновский `leaseMutex`, прецедент `MarkUploadRepository`), все зависимости — замыкания-seams (идиома `ApiClient`/`ScanModel`), зеркало `SyncCoordinatorTest` (~20 кейсов) переносится на фейках.
- **Lease-состояние — один `LeaseHolder`** (lock-guarded holder у `AppEnvironment`, по-swiftски воспроизводит андроидный `MutableStateFlow<RaceLease?>` с write-through в стор): координатор пишет через `writeLease`-замыкание, репозитории читают `isRacePinned` синхронно, UI подписывается на `AsyncStream` для живого тумблера.
- **`nowMs` для lease — wall clock (`Date()`), не `TrustedClock`** (deviation, документируется): `isRacePinned` нужен синхронно, а `TrustedClock` — actor-async; для 12-часового lease важна самосогласованность, не абсолютная точность — путь `lease_ttl_seconds` относительный и от сдвига часов не страдает.
- **Профиль Economy / «Экономия батареи» НЕ портируется** (`TrackProfile`/`TrackProfilePreference` умирают вместе с движковым слоем): на iOS `CLLocationUpdate.liveUpdates(.fitness)` не имеет настраиваемого интервала, «усыпить» геолокацию нельзя (без неё система suspend'ит процесс в фоне), а `.fitness` сам паузится на стоянках (`isStationary`). Пункт снимается с этапа в `android-port.md` с пометкой.
- **«Инфо о чипе» (GET_VERSION) и ряд «Администратор» — этап 10**; «Сменить команду» в шит не дублируется (уже есть в `TeamView`).
- **Настройки — `.sheet` из `TeamView`** (паттерн «Загрузка данных»), не оверлей как в Android.
- **Тема — `ThemePreference` + `.preferredColorScheme` на корне**: вся адаптивная палитра переключается системой, fixed-dark поверхности (`DarkHeroBackground`/`NFCTileView`) не трогаются.
- **Триггеры координации — ровно 3, без фоновых таймеров** (как в Android): тумблер, старт/смена команды, pull-to-refresh «Команды».

**Известный факт, не баг:** боевой сервер сегодня всегда отвечает `data_source: "cloud"` (`lease_expires_at: null`) → тумблер честно даст «Обновлено из интернета» и не запинится. Пин работает только против LAN-развёртки с `MOBILE_DATA_SOURCE=local` (проверяется локальным сервером из `Secrets.localAPIBaseURL`). Hard gate этапа — зелёный локальный сьют + сборка.

## Context (from discovery)

**Уже готово и переиспользуется (не переписывать):**
- `Net/ApiClient.swift:166` — `fetchSync(raceId:) async -> FetchResult<SyncManifestDto>` и `Net/Dto/SyncManifest.swift` — `SyncManifestDto` (зеркало `SyncDtos.kt`, `versions` сознательно игнорируется, эндпоинт без ETag) — готовы с этапа 3, потребитель — этот этап.
- `Net/URLSessionTransport.swift` — `ApiClients.makeDefaultPair()`: `localApi` уже существует (3 с таймаут, без time-anchor), подписывается тем же HMAC.
- Все 4 репозитория (`RaceRepository`/`TeamRepository`/`LegendRepository`/`MemberTagsRepository`) уже принимают `source: SyncSource` и (кроме Race) `isRacePinned: (Int) -> Bool`; двойные пин-гарды (до запроса + после 200) и партиция `sync_meta` по origin работают с этапа 3 — **правок не требуют**.
- `AppEnvironment.swift:169–189` — `isRacePinned` у всех зашит в `notPinned = { _ in false }` — единственная точка подмены.
- `AppModel.swift:344–390` — рефреш-оркестрация «всё `.cloud`» (Launch A/B, `refreshAll`, `refreshLegend`) — сюда встаёт `sourceFor`; `toastMessage` — готовый канал тостов.
- `Core/Util/RaceDates.swift` — `todayIso(now:)`/`nearestRaceId(races,today:)` (нужны `enterLocalMode`); `Core/Sync/SyncSource.swift`; `RefreshResult` в `RaceRepository.swift:28–35`.
- `Data/Stores/TrackStore.swift:85` — `deleteForTeam(teamId:raceId:)` (этап 2) + `countForTeam` (observation); `AppModel.trackRecorder.state` — guard «не во время записи».
- Идиомы: сторы на load/save-замыканиях (`InstallId`/`ClockAnchorStore`), `AsyncStream` `.bufferingNewest(1)` с ручным дедупом (`TrustedClock.statusUpdates`), `@Observable @MainActor`-модели только на `Observation`/`Foundation`, unstructured `Task` с захватом сторов (§6 этапа 5), тесты поверх `AppEnvironment.inMemory` + `FakeTransport`.
- `TeamView.swift:368` — приватный `MiscRowView` + `.sheet`-паттерн «Загрузка данных» (`UploadView`) — образец для входа в настройки.

**Kotlin-источники** (в `/Users/alff0x1f/src/kolco24_app_v2`, пакет `app/src/main/java/ru/kolco24/kolco24/`):
- `data/lease/RaceLease.kt` — `RaceLease(raceId, expiresAtMs)`, `DEFAULT_LEASE_MS = 12*60*60*1000`; `renewedLease(raceId, serverTtlSec?, serverLeaseExpiresAtSec?, nowMs)` — приоритет: TTL относительный → absolute epoch-sec → 12 ч дефолт; `isPinned` со **строгим `<`** на границе истечения; `sealed LeaseAction {Renew|Clear|Keep}`; `applySyncResponse(manifest?, raceId, nowMs)`: `null`/чужая гонка → `Keep`, `"local"` → `Renew`, `"cloud"` → `Clear`, иное → `Keep` (не пиниться на мусор).
- `data/lease/RaceLeaseStore.kt` — prefs, один ключ, формат `"raceId|expiresAtMs"`, парсинг строго 2 числовых части иначе `null`.
- `data/sync/SyncCoordinator.kt` — оркестратор на lambda-seams, `leaseMutex` сериализует probe/enter/exit; `sourceFor`, `probeLocalAndRenew`, `enterLocalMode`/`exitLocalMode`, `refreshAll` (пробa → fan-out с **перечитанным** `sourceFor`), `fanOut` (4 рефреша параллельно, изоляция ошибок), `combineRefreshResults`/`severity` (`HttpError>Forbidden>Offline>Updated>NotModified>Skipped`), `LocalModeOutcome {PinnedUntil(expiresAtMs,dataStale)|LocalNoPin|LocalUnreachable|CloudUpdated|Offline|NoRace}`. Полная матрица веток — в Task 4.
- `AppContainer.kt:150–273` + `Kolco24App.kt:34–101` + `MainActivity.kt:615–655` — wiring: `raceLease: MutableStateFlow` с write-through, `localModeBusy` app-scoped (переживает пересоздание UI), 3 триггера, тумблер derived-only от lease.
- `ui/settings/SettingsScreen.kt` — секции/ряды: `ThemeRow`+диалог, `ClearTrackRow` (сабтайтл «N точек», disabled при 0/записи), `LocalModeRow` (busy → спиннер вместо Switch, «Локальный режим до HH:mm» / «Обновление из интернета»), скрытая «Отладка» (10 тапов по `VersionRow` → тост «Меню отладки включено», в debug-сборке видна сразу; разблокировка per-composition), `VersionRow`. Confirm-диалоги: очистка трека (`MainActivity.kt:1978–2009`), reset team / clear DB (`DebugConfirmKind`).
- `data/ThemePreference.kt` + `ui/theme/ThemeMode.kt` — ключ `"theme_mode"`, `enum {SYSTEM, LIGHT, DARK}`, дефолт/мусор → SYSTEM.
- Дизайн-док: `docs/plans/completed/20260702-local-mode-switch.md` (авторитетная спецификация lease/переключения — код ей соответствует).
- **Android-тесты для зеркалирования:** `RaceLeaseTest.kt`, `RaceLeaseStoreTest.kt`, `SyncCoordinatorTest.kt` (~20 кейсов на фейках с логом вызовов), `ThemePreferenceTest.kt`. `TrackProfileTest`/`TrackProfilePreferenceTest` — **не портируются** (Economy снят).

## Development Approach

- **testing approach**: порт-конвенция этапов 2–8 — Kotlin-тесты переносятся вместе с модулем в той же задаче (имена кейсов 1:1, header «Зеркало …»); для `LeaseHolder`, `SettingsModel`, `wipeAllTables` и UI зеркала нет — тесты свежие (regular: код → тесты в той же задаче) поверх `AppEnvironment.inMemory` + `FakeTransport`;
- complete each task fully before moving to the next;
- make small, focused changes (коммит на задачу);
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task;
- **CRITICAL: all tests must pass before starting next task**;
- **CRITICAL: update this plan file when scope changes during implementation**.

## Testing Strategy

- **unit tests**: Swift Testing. `kolco24Tests/Core/RaceLeaseTests`, `RaceLeaseStoreTests`, `LeaseHolderTests`, `ThemePreferenceTests`; `kolco24Tests/Data/Sync/SyncCoordinatorTests` (фейки-замыкания с логом вызовов, без БД/сети); `kolco24Tests/Data/AppDatabaseWipeTests`; `kolco24Tests/App/SettingsModelTests` (`@MainActor`, `AppEnvironment.inMemory` + `FakeTransport`) + дополнение `AppModelTests` (LAN-проба при pinned-гонке по логу `FakeTransport`).
- **e2e**: автоматизированных нет. Пин против настоящего LAN-сервера проверяется вручную (Post-Completion); тема/трек/отладка — руками в симуляторе.
- Прогон: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'` (нужен `Config/Secrets.xcconfig`; при флаки-имени — `id=<UDID>` из `xcrun simctl list devices available`).

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

Слои (сверху вниз):
- **UI**: `SettingsView` (шит из `TeamView`) → `SettingsModel`.
- **App**: `SettingsModel` (@Observable, derived-тумблер от lease-стрима, тосты) + `AppModel` (3 триггера координации, `localModeBusy`, `themeMode` + `.preferredColorScheme` на корне).
- **Data**: `SyncCoordinator` (actor, оркестрация probe/enter/exit/refreshAll поверх 4 репозиториев) — в `Data/Sync/`, т.к. оперирует `RefreshResult`/репозиториями (прецедент stage-3 refresh flow).
- **Core**: `RaceLease` (чистая lease-математика), `LeaseHolder` (thread-safe состояние + стрим), `RaceLeaseStore`/`ThemePreference` (UserDefaults-сторы).
- **Композиция**: `AppEnvironment` владеет `leaseHolder` + `syncCoordinator`, подменяет `isRacePinned` у трёх pin-guard-репозиториев на реальный lease-чек.

Поток данных при включении тумблера: `SettingsModel.toggleLocalMode(true)` → `AppModel` (busy=true, fire-and-forget Task) → `coordinator.enterLocalMode()` → `localApi.fetchSync` → `applySyncResponse` → `writeLease` → `LeaseHolder` (persist в UserDefaults + публикация в стрим) → `SettingsModel` пересчитывает тумблер/сабтайтл; параллельно fan-out 4 рефрешей с `source: .local` → пин-гарды пропускают LAN-записи → outcome → тост.

## Technical Details

- Ключи UserDefaults: `race_lease` (формат `"raceId|expiresAtMs"`), `theme_mode` (`"SYSTEM"|"LIGHT"|"DARK"` — uppercase rawValues, байт-в-байт как Kotlin `.name`, чтобы зеркало `ThemePreferenceTest` осталось дословным).
- `DEFAULT_LEASE_MS: Int64 = 12 * 60 * 60 * 1000`.
- `SyncManifestDto` (есть): `race: Int`, `dataSource: String`, `leaseTtlSeconds: Int64?`, `leaseExpiresAt: Int64?` (epoch-секунды); `versions` игнорируется.
- Severity-свёртка fan-out: `httpError(5) > forbidden(4) > offline(3) > updated(2) > notModified(1) > skipped(0)`; успех = `{updated, notModified, skipped}`.
- Тосты по `LocalModeOutcome`: `pinnedUntil` → «Локальный режим до HH:mm» (+ « (данные не обновлены)» при `dataStale`), `localNoPin` → «Обновлено из интернета», `localUnreachable` → «Локальный сервер недоступен», `cloudUpdated` → «Обновлено из интернета», `offline` → «Нет сети», `noRace` → «Гонка не выбрана».
- «до HH:mm» — `Date.FormatStyle.dateTime.hour().minute()`, локальная таймзона.
- Deviation-очистка трека: без андроидной перепроверки guard под upload-мьютексом — гонка «drain дошлёт удалённую точку» безвредна (`markUploaded*` по несуществующим id — no-op), guard `trackRecorder.state == .idle` проверяется на подтверждении диалога.

## What Goes Where

- **Implementation Steps** (`[ ]`): код, тесты, документация в этом репозитории.
- **Post-Completion** (без чекбоксов): ручная проверка на устройстве/против LAN-сервера.

## Implementation Steps

### Task 1: Core — RaceLease (порт 1:1)

**Files:**
- Create: `kolco24/Core/Lease/RaceLease.swift`
- Create: `kolco24Tests/Core/RaceLeaseTests.swift`

- [x] `struct RaceLease: Equatable { let raceId: Int; let expiresAtMs: Int64 }` + `DEFAULT_LEASE_MS`
- [x] `renewedLease(raceId:serverTtlSec:serverLeaseExpiresAtSec:nowMs:) -> RaceLease` — приоритет TTL → absolute → 12 ч
- [x] `isPinned(_ lease: RaceLease?, raceId: Int, nowMs: Int64) -> Bool` — строгое `<` на границе
- [x] `enum LeaseAction: Equatable { case renew(RaceLease), clear, keep }` + `applySyncResponse(race: Int?, dataSource: String?, ttlSec: Int64?, expiresAtSec: Int64?, raceId: Int, nowMs: Int64) -> LeaseAction` — принимает **разобранные поля** (не DTO): `SyncManifestDto` живёт в `Net/Dto/`, а `Core/` от `Net/` не зависит; манифест-`nil` кодируется `race: nil`; маппинг из DTO — на стороне координатора (прецедент `PhotoFrameInput`)
- [x] зеркало `RaceLeaseTest.kt` → `RaceLeaseTests` (приоритет TTL > absolute > default; границы `isPinned` вкл. строгое `<`, чужую гонку, просроченный серверный lease; `applySyncResponse` renew/clear/keep для nil/чужой гонки/неизвестного source)
- [x] run tests - must pass before next task

### Task 2: Core — RaceLeaseStore + LeaseHolder

**Files:**
- Create: `kolco24/Core/Stores/RaceLeaseStore.swift`
- Create: `kolco24/Core/Lease/LeaseHolder.swift`
- Create: `kolco24Tests/Core/RaceLeaseStoreTests.swift`
- Create: `kolco24Tests/Core/LeaseHolderTests.swift`

- [x] `RaceLeaseStore` в идиоме `ClockAnchorStore`: load/save-замыкания + `fromUserDefaults` (ключ `race_lease`); encode `"raceId|expiresAtMs"`, decode строго 2 числовых компонента через `components(separatedBy:)`, иначе `nil`; `save(nil)` удаляет ключ
- [x] `LeaseHolder`: `final class`, значение под `NSLock`; sync `var value: RaceLease?`; `set(_:)` — write-through в persist-замыкание + публикация в `nonisolated` `AsyncStream<RaceLease?>` (`.bufferingNewest(1)`, дедуп равных значений вручную — идиома `TrustedClock.statusUpdates`); сидится из стора при создании
- [x] зеркало `RaceLeaseStoreTest.kt` → `RaceLeaseStoreTests` (round-trip, один ключ, clear, pre-seeded read, отбраковка мусора: лишние/недостающие/нечисловые части, пустая строка)
- [x] свежие `LeaseHolderTests` (сид из стора, write-through, стрим публикует изменения и дедупит равные)
- [x] run tests - must pass before next task

### Task 3: Core — ThemePreference

**Files:**
- Create: `kolco24/Core/Stores/ThemePreference.swift`
- Create: `kolco24Tests/Core/ThemePreferenceTests.swift`

- [x] `enum ThemeMode: String, CaseIterable { case system = "SYSTEM", light = "LIGHT", dark = "DARK" }` (uppercase rawValues — персист-формат 1:1 с Kotlin `.name`, зеркальные ассерты строк остаются дословными) + `parseThemeMode(_ raw: String?) -> ThemeMode` (nil/мусор → `.system`)
- [x] стор в той же идиоме (ключ `theme_mode`, load/save + `fromUserDefaults`), sync-чтение при создании, `setMode` персистит `rawValue`
- [x] зеркало `ThemePreferenceTest.kt` → `ThemePreferenceTests` (дефолт system, pre-seeded, unknown → system, персист + reload новым инстансом)
- [x] run tests - must pass before next task

### Task 4: Data/Sync — SyncCoordinator (actor)

**Files:**
- Create: `kolco24/Data/Sync/SyncCoordinator.swift`
- Create: `kolco24Tests/Data/Sync/SyncCoordinatorTests.swift`

- [x] `actor SyncCoordinator` c зависимостями-замыканиями: `readLease/writeLease/nowMs/fetchSync: (Int) async -> SyncManifestDto?` (координатор — в `Data/`, DTO ему виден; в `applySyncResponse` передаёт разобранные поля) `/selectedRaceId/cachedRaces/refreshRaces(source)/refreshTeams|Legend|MemberTags(raceId, source)`; `enum LocalModeOutcome: Equatable` (6 кейсов)
- [x] `nonisolated func sourceFor(_ raceId:) -> SyncSource` (замыкания sync — без actor-hop)
- [x] `probeLocalAndRenew(raceId)` — heartbeat: `applySyncResponse` → renew→`writeLease(lease)` / clear→`writeLease(nil)` / keep→ничего
- [x] `enterLocalMode()` — полная матрица веток 1:1: резолв гонки (selected → при пустом кэше сначала `refreshRaces(.local)`; пусто и pull неуспешен → `.localUnreachable`; `nearestRaceId(races, todayIso())`; нет → `.noRace`) → `fetchSync` → `applySyncResponse`: renew+ещё `isPinned` → write + fanOut(.local) → `.pinnedUntil(expiresAtMs, dataStale: fan-out не успешен)`; renew но уже просрочен → `writeLease(nil)` + fanOut(.cloud) → `.localNoPin`; clear → то же `.localNoPin`; keep + manifest==nil → `.localUnreachable` (ничего не пишем); keep + манифест есть → fanOut(.cloud), `.localNoPin`
- [x] `exitLocalMode()` — безусловный `writeLease(nil)` → fanOut(.cloud) (или голый `refreshRaces(.cloud)` без гонки) → `.cloudUpdated` если свёртка успешна, иначе `.offline` (403/5xx ≠ успех)
- [x] `refreshAll(raceId)` — если pinned: сначала проба, потом fanOut с **перечитанным** `sourceFor`; `fanOut` = 4 рефреша параллельно (`async let`, ошибки-значения), свёртка `combineRefreshResults(_:) `/`severity` — чистые хелперы рядом
- [x] зеркало `SyncCoordinatorTest.kt` → `SyncCoordinatorTests` (~20 кейсов на фейках с логом вызовов: sourceFor ×2; probe renew/clear/keep; enterLocalMode — pin+local-fan-out, pin+stale, cloud-source→no-pin, unreachable-ничего-не-пишет, пустой кэш→LAN-races-сначала, NoRace, LocalUnreachable-при-пустом-кэше-и-неуспешном-pull, просроченный-серверный-lease→активный-unpin; exitLocalMode — always-unpin, offline, unpin-без-гонки, http/forbidden≠успех; refreshAll — unpinned-не-трогает-LAN, pinned-probe-затем-local, handback-во-время-пробы→cloud, unreachable-проба→остаёмся-local; combineRefreshResults severity + пустой список)
- [x] run tests - must pass before next task

### Task 5: Композиция — AppEnvironment + триггеры в AppModel

**Files:**
- Modify: `kolco24/App/AppEnvironment.swift`
- Modify: `kolco24/App/AppModel.swift`
- Modify: `kolco24/kolco24App.swift` (или `ContentView.swift` — где корень)
- Modify: `kolco24Tests/App/AppModelTests.swift`

- [x] `AppEnvironment`: `let leaseHolder: LeaseHolder` (сид из `RaceLeaseStore.fromUserDefaults`; `inMemory` — in-memory load/save), `let themePreference: ThemePreference`, `let syncCoordinator: SyncCoordinator` (fetchSync поверх `localApi.fetchSync` — `.success` → DTO, иначе `nil`; `nowMs = { Int64(Date().timeIntervalSince1970 * 1000) }`). ⚠️ Порядок конструирования в `private init` (в **обоих** фабриках): `leaseHolder` — до блока репозиториев (его захватывает `isRacePinned`), `syncCoordinator` — после (захватывает `refresh*` репозиториев + local-клиент)
- [x] `isRacePinned` трёх репозиториев: `notPinned` → `{ raceId in isPinned(leaseHolder.value, raceId: raceId, nowMs: …) }`
- [x] `AppModel`: Launch A/B и `refreshLegend` — источник `coordinator.sourceFor(raceId)` вместо захардкоженного `.cloud`; в observation `selectedTeamStore` при смене гонки: если `sourceFor == .local` → сначала `await probeLocalAndRenew(raceId)`, затем fan-out с перечитанным `sourceFor`; `refreshAll()` делегирует `coordinator.refreshAll(raceId)` (тост из свёрнутого `RefreshResult` как раньше)
- [x] `AppModel`: `var localModeBusy: Bool` + `toggleLocalMode(_ on: Bool)` (fire-and-forget Task с захватом координатора — busy переживает закрытие шита; сброс `localModeBusy = false` — гарантированно по возврату вызова координатора, `defer`/finally, иначе спиннер залипнет; outcome → русский тост через `toastMessage`); `var themeMode: ThemeMode` (сид из стора, сеттер персистит)
- [x] корень: `.preferredColorScheme(appModel.themeMode.colorScheme)` (`system → nil`, `light → .light`, `dark → .dark`; маленький расширение-маппер в UI-слое)
- [x] дополнение `AppModelTests`: при посеянном lease смена команды шлёт запросы на LAN-origin и пробу `/sync/` (по логу `FakeTransport`); `toggleLocalMode` против `FakeTransport` c `data_source: "local"` пинит и включает busy-цикл
- [x] run tests - must pass before next task

### Task 6: Data — AppDatabase.wipeAllTables

**Files:**
- Modify: `kolco24/Data/AppDatabase.swift`
- Create: `kolco24Tests/Data/AppDatabaseWipeTests.swift`

- [x] `func wipeAllTables() async throws` — одна транзакция `DELETE FROM …` по всем 13 таблицам (без erase+remigrate в рантайме; список таблиц — из инвентаря схемы)
- [x] тест: посеять по строке в несколько таблиц (вкл. `selected_team`, `sync_meta`) → wipe → все таблицы пусты, схема жива (повторный insert работает)
- [x] run tests - must pass before next task

### Task 7: App — SettingsModel

**Files:**
- Create: `kolco24/App/SettingsModel.swift`
- Create: `kolco24Tests/App/SettingsModelTests.swift`
- Modify: `kolco24/App/AppModel.swift` (`makeSettingsModel()`)

- [x] `@Observable @MainActor final class SettingsModel` (только `Observation`/`Foundation`), минтится `AppModel.makeSettingsModel()` для текущих `raceId`/`teamId`
- [x] derived-тумблер: подписка на `leaseHolder`-стрим (сид текущим значением) → `localModeOn = isPinned(lease, raceId, now)`, `localModeSubtitle` («Локальный режим до HH:mm» / «Обновление из интернета»); `localModeBusy` проксирует `AppModel`
- [x] `toggleLocalMode(_:)` → `AppModel.toggleLocalMode`; `themeMode` get/set → `AppModel`
- [x] трек: подписка `trackStore.countForTeam` → `trackPointCount`, `clearTrackEnabled = count > 0 && рекордер не пишет эту команду`; `clearTrack()` — перепроверка `trackRecorder.state == .idle` → `trackStore.deleteForTeam` в unstructured Task с захватом стора (§6)
- [x] отладка: `resetTeam()` → `AppModel.clearTeam()`; `wipeDatabase()` → `env.database.wipeAllTables()` (fire-and-forget, тост «База очищена»)
- [x] `versionLabel` — `CFBundleShortVersionString (CFBundleVersion)` из инжектированных значений (тестируемость)
- [x] `SettingsModelTests`: derived-тумблер от посеянного lease + реакция на стрим; toggle → busy → тост по outcome (через `FakeTransport`); `clearTrackEnabled` false при записи/нуле; `clearTrack` удаляет точки; wipe очищает таблицы
- [x] run tests - must pass before next task

### Task 8: UI — SettingsView + вход из TeamView

**Files:**
- Create: `kolco24/SettingsView.swift`
- Modify: `kolco24/TeamView.swift`

- [x] ряд «Настройки» (`gearshape.fill`, `MiscRowView`) в misc-секции `TeamView` → `.sheet` с `SettingsView(model: appModel.makeSettingsModel())` (паттерн «Загрузка данных»)
- [x] `List` в стиле `UploadView` (design-токены): секция «Внешний вид» — `Picker` (`.menu`) Системная/Светлая/Тёмная
- [x] секция «Запись трека» — «Очистить трек» (сабтайтл `pointsLabel(N)` из `PluralRu`, disabled при `!clearTrackEnabled`) → `confirmationDialog` («Все записанные точки этой команды будут удалены без возможности восстановления.», destructive «Очистить»)
- [x] секция «Данные» — «Локальный сервер (Wi-Fi гонки)»: `Toggle`; при `localModeBusy` — `ProgressView` вместо тумблера, ряд заблокирован; сабтайтл из модели
- [x] секция «О приложении» — «Версия»; 10 тапов → `debugUnlocked = true` (state вью, сбрасывается при закрытии шита) + тост «Меню отладки включено»; в `#if DEBUG` секция видна сразу
- [x] скрытая секция «Отладка» — «Сбросить команду» и «Очистить базу данных», оба через `confirmationDialog`
- [x] прогон полного сьюта + сборка (UI-задача без своих юнитов — hard gate не ослабляется)
- [x] run tests - must pass before next task

### Task 9: Верификация приёмки

- [x] пройтись по Overview: пин/handback/истечение, 3 триггера, тумблер derived, тема, очистка трека с guard, отладка за 10 тапами — всё реализовано
- [x] grep-инварианты: `Core/Lease`/`Core/Stores` — только Foundation; `import GRDB` не появился вне `Data/`; `SettingsModel` — только `Observation`/`Foundation`; `Data/Sync/SyncCoordinator` без UIKit/SwiftUI
- [x] edge cases: lease чужой гонки не пинит; просроченный на приёме серверный lease активно снимается; `keep` при недоступном LAN не трогает lease; busy-тумблер не даёт двойного входа (actor)
- [x] полный сьют: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'`
- [x] сборка: `xcodebuild -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16' build`

### Task 10: [Final] Документация

- [x] обновить `CLAUDE.md`: новый раздел «LAN & settings layer» (lease/holder/координатор/настройки, deviation по wall clock и по guard очистки трека, grep-инварианты)
- [x] обновить `docs/plans/android-port.md`: этап 9 → ✅ со ссылкой; пункт Economy/`TrackProfilePreference` снят с пометкой «не портируется — на iOS `liveUpdates(.fitness)` сам управляет питанием»; «Инфо о чипе» отмечено как перенесённое в этап 10
- [x] переместить этот план в `docs/plans/completed/`

## Post-Completion

**Ручная проверка (симулятор):**
- тема: переключение Системная/Светлая/Тёмная мгновенно перекрашивает адаптивные токены, fixed-dark поверхности не меняются; выбор переживает перезапуск
- очистка трека: после записи трека (данные с этапа 8) счётчик точек в сабтайтле, диалог, обнуление TrackCard; ряд задизейблен во время записи
- отладка: 10 тапов открывают секцию, reset team возвращает пустые состояния, wipe БД очищает все вкладки

**Ручная проверка (LAN-сервер, `MOBILE_DATA_SOURCE=local`):**
- тумблер: пин («Локальный режим до HH:mm»), данные тянутся с LAN-хоста; выключение — handback на cloud; повторный запуск приложения при живом lease — re-probe и LAN-данные; недоступный LAN при включении — «Локальный сервер недоступен», lease не записан
- handback сервером (`data_source: "cloud"`) на pull-to-refresh снимает пин, тумблер гаснет сам

**Известный факт:** против боевого сервера тумблер всегда даст «Обновлено из интернета» (сервер отвечает `data_source: "cloud"`) — это спроектированное поведение, не регрессия.
