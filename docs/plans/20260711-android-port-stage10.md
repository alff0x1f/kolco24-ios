# Этап 10 портирования: Админ-режим

Детализация этапа 10 из [android-port.md](android-port.md). Этапы 0–9 выполнены: чистая логика, GRDB-слой, сеть/sync, `@Observable`-модели, NFC-скан, выгрузка взятий, фото-отметка, GPS-трек, LAN-режим и настройки готовы и покрыты тестами. Этап 10 добавляет админ-режим: логин организатора (bearer-токен в Keychain), судейские отметки старта/финиша, две read-only проверки чипов (КП-чип и браслет) и провижининг — привязку чипа к КП с записью кода на чип.

## Overview

Организатор в настройках открывает «Администратор» → логин email/пароль (`POST /app/login/` → opaque-токен на 30 дней) → меню из 5 действий: «Привязать чип к КП» (провижининг), «Проверить чип КП», «Проверить чип участника», «Отметка старта», «Отметка финиша», плюс «Выйти». Bearer-токен добавляется к **обоим** клиентам (cloud + LAN) поверх 6 подписных `X-App-*` заголовков и в HMAC-canonical не входит (шов `tokenProvider` готов с этапа 3).

Судейский скан: судья на старте/финише прикладывает браслеты участников — каждый распознанный по пулу `member_tags` UID пишется write-once строкой в локальную таблицу `judge_scans` (уже в схеме v1) и идемпотентно дренится на обе цели (эндпоинт на сервере ещё не задеплоен — pending/self-heal, как было с `/marks/`). Проверки чипов — полностью оффлайн-идентификация по `bid`/UID против синхронизированной легенды/пула, без записи. Провижининг: сервер по `POST /app/race/<id>/tags/` выдаёт 16-байтный код, приложение пишет его на чип (`writeRecord` header-last + read-back — чистая логика готова с этапа 1).

**Ключевые решения брейншторма (адаптация под платформу, не 1в1 из Kotlin):**
- **NFC — обобщение существующего `NfcChipScanner`** через инжектируемый per-tag обработчик `(NfcTransport, uid, TimeSample) -> R` на `readQueue`; одна долгая сессия на экран (batch-скан как на Android). Session-менеджмент (restart, debounce, deadlock-дисциплина) не дублируется; протокол `ChipScanning` и скан/bind-флоу этапа 5 **не трогаются** — `NfcChipScanner` становится тонкой обёрткой с обработчиком `readRecord`.
- **Провижининг — двухтаповый флоу** (deviation от Android, где чип держат у телефона весь server-roundtrip): тап 1 — uid → `bindTag` → сервер выдал `code` → «Приложите чип ещё раз»; тап 2 — сверка **того же** uid (чужой чип → отказ без записи) → `writeRecord` + read-back. Надёжно при медленной сети на старте; header-last гарантирует безопасность повтора.
- **Rotation-survival машинерия Android не портируется** (`provisioningPendingCleanup`/`AtomicBoolean`/`freshTokens` в `AppContainer`): на iOS `@Observable`-модель живёт, пока открыт `fullScreenCover`, поворот её не убивает. Сетевые/дисковые операции — в unstructured `Task` с захватом зависимостей (§6), закрытие экрана их не рвёт.
- **UI провижининга — список/степпер КП вместо `HorizontalPager` + rail-тиков** (идиоматичный iOS-паттерн, `railTicks` не портируется).
- **«Инфо о чипе» (GET_VERSION) НЕ реализуется вообще** (решение пользователя; `chipModelFromVersion` остаётся в Core как мёртвый протестированный код этапа 1). В `android-port.md` пометить как не портируется.
- **Токен — один Keychain-item** (`kSecClassGenericPassword`, service `kolco24.admin`) с JSON `{token, email, expiresAt}` — атомарность «сессия целиком или ничего» (прецедент `RaceLeaseStore` с одной строкой), вместо трёх ключей Android.
- **Триггеры судейского дрейна**: fire-and-forget flush сразу после каждой записанной отметки **плюс** выделенный 60-секундный цикл, пока судейский экран открыт (аналог Android-цикла, но привязанный к жизни экрана), плюс расширение существующего 5-минутного цикла и team-change flush.
- **Навигация**: ряд «Администратор» в `SettingsView` (всегда видимый, как в Android) → `fullScreenCover` с `AdminFlowView` (свой `NavigationStack`, прецедент `TeamPickerFlowView`) → push суб-экранов.

**Известный факт, не баг:** эндпоинт `POST /app/race/<id>/judge_scans/` на сервере не реализован — судейские строки останутся pending («ошибка»/«сервер недоступен»), self-heal дошлёт их той же сборкой после деплоя (спроектированное поведение, как было с `/marks/` и фото). Hard gate этапа — зелёный локальный сьют + сборка; запись чипов проверяется руками на реальных NTAG (Post-Completion).

## Context (from discovery)

**Уже готово и переиспользуется (не переписывать):**
- `Data/Stores/JudgeScanStore.swift` (этап 2, зеркало `JudgeScanDao`): `insert`, `unuploadedLocal/Cloud(raceId:limit:)` (сортировка `COALESCE(trustedTakenAt, takenAt), id`), `markUploadedLocal/Cloud(ids:)` (**без** version-guard — write-once), `pendingUploadRaces()`, `uploadCounts(raceId:)` observation. Доменный тип `Model/JudgeScan.swift`; таблица `judge_scans` в миграции v1.
- `Net/ApiClient.swift:50,387` — `tokenProvider: () -> String?`: bearer уже добавляется, когда провайдер non-nil, и **не входит** в canonical. Единственная точка подмены — `AppEnvironment` (сейчас `{ nil }`).
- `Core/Nfc/ChipRecord.swift` — чистые `writeRecord` (header-last + read-back verify, `ChipWriteResult` значением, никогда не бросается), `readRecord`, `buildChipRecord`, `chipCodeFromHex`/`chipCodeHex`, `protocol NfcTransport` — протестированы (этап 1). `Nfc/MiFareTransport.swift` — прод-транспорт, generic-транзивер, не меняется.
- `Data/Repositories/MarkUploadRepository.swift` — общий `drainUploadLoop<Row>` (empty-first-fetch → `nil`; drained → `.ok`; non-success → его kind; **accepted ∩ batch пусто → `.error`** anti-loop), `uploadBatch = 500`, идиома actor + `inFlight`, `TargetUploadOutcome`, outcomes-стримы `.bufferingNewest(1)`; `TrackUploadRepository` — образец клона без version-guard.
- Идиомы: сторы на load/save-замыканиях (`ClockAnchorStore`/`RaceLeaseStore`), `LeaseHolder` (NSLock + sync value + `AsyncStream` с seed/дедупом), §6 «unstructured Task с захватом сторов», `@Observable @MainActor`-модели только на `Observation`/`Foundation`, `FakeTransport`-тесты поверх `AppEnvironment.inMemory`, `ScanFeedbackPlaying`, `FakeChipScanner` в превью/тестах.
- `MemberTagsRepository.hasBeenSynced`/inline `refreshMemberTags` — гейт «пул синхронизирован, но пуст» (bind-флоу этапа 5, тот же нужен судейскому скану). `LegendCrypto.bid(code)` — для проверки КП-чипа.
- `SettingsView.swift` (этап 9) — секции, `MiscRowView`-паттерн; `UploadView.swift`/`App/UploadModel.swift` — секции Отметки/Фото/Трек, правила receipt-строк; `TeamPickerFlowView` — прецедент fullScreenCover + NavigationStack.
- `InstallId.fromUserDefaults()` — `sourceInstallId` для судейских строк (тот же UUID, что в `X-Install-Id`).

**Kotlin-источники** (в `/Users/alff0x1f/src/kolco24_app_v2`, пакет `app/src/main/java/ru/kolco24/kolco24/`):
- `data/AdminTokenStore.kt` — 3 ключа в отдельном prefs-файле `kolco24.admin`; `read()` → null, если **любой** ключ отсутствует; iOS-замена — один Keychain-item.
- `data/AdminAuthRepository.kt` — `AdminSession` sealed (`:18`), синхронный сид при конструировании (`seedSession :98`, протухшая сессия → clear + LoggedOut), `token()` — sync-чтение для интерцептора (`:59`), `login`/`logout` (`:66`/`:80` — logout чистит **всегда**, даже оффлайн), `onUnauthorized` (`:93`), `isExpired` — **лексикографическое** сравнение фиксированных ISO-UTC строк, граница = истёк (`:140`), `loginOutcome`/`adminErrorMessage` (`:114`/`:126`).
- `data/api/ApiClient.kt` — `login`/`logout` (`:167–178`), `bindTag` (`:186`), `uploadJudgeScans` (`:245`); `data/api/AppSignatureInterceptor.kt:105` — bearer поверх подписи.
- `data/api/dto/AuthDtos.kt` (`LoginRequest{email,password}`, `LoginResponse{token, expires_at}` — UTC `Z`-ISO), `JudgeScanDtos.kt` (request **без** `team_id`; ренеймы `wall_ms←takenAt`, `trusted_ms←trustedTakenAt`, `elapsed_at←elapsedRealtimeAt`), `TagDtos.kt` (`TagBindRequest{checkpoint_id, nfc_uid}` — стабильный id, не номер; `TagBindResponse{bid, checkpoint_id, number, nfc_uid, code}` — `code` 16-байтный hex).
- `data/JudgeScanRepository.kt` — `record` (`:65`), дуал-таргет `uploadLoop` (`:141`), `uploadMutex.tryLock`.
- `ui/admin/JudgeScanModel.kt` (`classifyJudgeScan :52` — порядок веток: `!poolReady` → PoolNotReady; matched → Recorded; `hasKpCode` → KpChip; else UnknownChip; **только Recorded пишет**), `ChipCheckModel.kt` (`classifyChipCheck :101`, `changedNibbles :86`), `MemberChipCheckModel.kt` (`:64`), `ProvisioningModel.kt` (`ProvisionState :21`, `provisionErrorMessage :77`, `chipTokenLabel :92`).
- `ui/admin/{AdminScreen,JudgeScanScreen,CheckChipScreen,CheckMemberChipScreen,ProvisioningScreen}.kt` — хосты (поведенческий референс, структура не портируется).
- `data/nfc/MifareUltralightWriter.kt` — `writeRecord :191` / `writeChipCode :256` (эталон уже портированной записи).
- Доки: `docs/mobile-admin-auth-and-tags.md` (авторитетный контракт login/logout/tags: 201/200/409/404/401/429, rate limits 5/min и 60/min), `docs/design/UPLOAD.md:313,363` (judge_scans; только Recorded уходит на сервер).
- **Android-тесты для зеркалирования:** `AdminTokenStoreTest.kt`, `AdminAuthRepositoryTest.kt`, `SigningTest.kt` (bearer-кейсы), `ApiClientTest.kt` (login/logout/bindTag), `JudgeScanRepositoryTest.kt`, `JudgeScanDtoTest.kt`, `JudgeScanModelTest.kt`, `ChipCheckModelTest.kt`, `MemberChipCheckModelTest.kt`, `ProvisioningModelTest.kt` (минус `railTicks`). `MifareUltralightWriterTest` уже зеркалирован на этапе 1; кейсы `chipModelFromVersion`/GET_VERSION — сняты вместе с фичей.

## Development Approach

- **testing approach**: порт-конвенция этапов 2–9 — Kotlin-тесты переносятся вместе с модулем в той же задаче (имена кейсов 1:1, header «Зеркало …»); для `AdminSessionHolder`, моделей экранов и UI зеркала нет — тесты свежие (regular: код → тесты в той же задаче) поверх `AppEnvironment.inMemory` + `FakeTransport`/`FakeChipScanner`;
- complete each task fully before moving to the next;
- make small, focused changes (коммит на задачу);
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task;
- **CRITICAL: all tests must pass before starting next task**;
- **CRITICAL: update this plan file when scope changes during implementation**.

## Testing Strategy

- **unit tests**: Swift Testing. `kolco24Tests/Core/AdminTokenStoreTests`, `AdminSessionTests`, `AdminSessionHolderTests`, `JudgeScanLogicTests`, `ChipCheckLogicTests`, `MemberChipCheckLogicTests`, `ProvisioningLogicTests`; `kolco24Tests/Net/` — дополнения `SigningTests` (bearer) и `ApiClientTests` (login/logout/bindTag/uploadJudgeScans статус-матрица), `JudgeScanDtoTests`; `kolco24Tests/Data/Repositories/AdminAuthRepositoryTests`, `JudgeScanUploadRepositoryTests`; `kolco24Tests/App/JudgeScanModelTests`, `ProvisioningModelTests`, `ChipCheckModelTests` + дополнения `UploadModelTests`/`AppModelTests`.
- **e2e**: автоматизированных нет. Логин против живого сервера — best-effort (образец `LiveServerSmokeTests`); NFC-часть (сканы, запись) — только на устройстве (Post-Completion).
- Прогон: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'` (нужен `Config/Secrets.xcconfig`; при флаки-имени — `id=<UDID>` из `xcrun simctl list devices available`).

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

Слои (сверху вниз):
- **UI**: ряд «Администратор» в `SettingsView` → `AdminFlowView` (fullScreenCover + NavigationStack): `AdminHomeView` (логин-форма или меню) → push `JudgeScanView` / `CheckChipView` / `CheckMemberChipView` / `ProvisioningView`.
- **App**: `JudgeScanModel`, `ChipCheckModel`, `MemberChipCheckModel`, `ProvisioningModel` (@Observable @MainActor, минтятся фабриками `AppModel`); `UploadModel` получает секцию «Судейские отметки»; `AppModel` — триггеры дрейна.
- **Data**: `AdminAuthRepository` (login/logout/onUnauthorized поверх `PostResult`), `JudgeScanUploadRepository` (дрейн-клон `TrackUploadRepository` с ключом `raceId`).
- **Net**: `AuthDtos`, `JudgeScanUpload`, `TagBind` + `ApiClient.login/logout/uploadJudgeScans/bindTag`.
- **Core**: `AdminSession` (+ `isExpired`, `LoginOutcome`), `AdminSessionHolder`, `AdminTokenStore` (Keychain), `JudgeScanLogic`, `ChipCheckLogic`, `ProvisioningLogic` — всё Foundation-only, зеркальные тесты.
- **Nfc**: обобщение `NfcChipScanner` per-tag обработчиком; pending-write ячейка для провижининга.
- **Композиция**: `AppEnvironment` — `adminSessionHolder` строится **до** клиентов (оба получают `tokenProvider`), `adminAuthRepository`/`judgeScanUploadRepository` — после.

Поток судейского скана: тап браслета → сканер (K24-обработчик) → `TagReading` → `JudgeScanModel`: пул `member_tags` + `hasBeenSynced`-гейт → `classifyJudgeScan` → `recorded` → `makeJudgeScan` → `judgeScanStore.insert` (unstructured Task, §6) → fire-and-forget `uploadPending(raceId)` → фидбек/лента. Поток провижининга: тап 1 → uid → `bindTag` → `code` из ответа → pending-write ячейка сканера → «Приложите ещё раз» → тап 2 → сверка uid → `writeRecord` + read-back → success → автопереход к следующему КП.

## Technical Details

- **Keychain**: один item `kSecClassGenericPassword`, service `kolco24.admin`, JSON `{token, email, expiresAt}`. `read()` → `nil`, если item отсутствует / JSON битый / любое поле пустое; `save(nil)` удаляет item. Чистое ядро на `load/save: (Data?)`-замыканиях живёт в `Core/Stores/` (Foundation-only, инвариант этапа 9 не ломается); прод-адаптер — в **новой платформенной папке `Keychain/`** (прецедент `Nfc/`/`Location/`/`Audio/`/`Photo/`) — **единственное** место `SecItem*`/`import Security` в проекте.
- **Expiry**: `expires_at` — фиксированный `yyyy-MM-dd'T'HH:mm:ss'Z'` UTC; `isExpired(expiresAt:nowUtcIso:)` — лексикографическое `>=` (граница = истёк), `nowUtcIso` инжектируемый.
- **`LoginOutcome`**: `.unauthorized → invalidCredentials` (401 — сервер нарочно не различает «нет такого» и «не тот пароль»), `.rateLimited → rateLimited` (5/min/IP), `.offline → offline`, прочее → `error`. Русские строки `adminErrorMessage` — **дословно из Kotlin** (`AdminAuthRepository.kt:126–132`, зеркальный тест ассертит их байт-в-байт): «Неверный email или пароль», «Слишком много попыток входа. Попробуйте позже», «Нет соединения с сервером», «Не удалось войти. Попробуйте ещё раз».
- **DTO judge_scans** (`snake_case`, ручной `encode(to:)` по nullable-правилу этапа 6 — `trusted_ms`/`boot_count` пишутся явным `null`): request `{source_install_id, scans}` — **без `team_id`** (судейская станция сканирует все команды; `raceId` только в пути); `JudgeScanDto{id, event_type, participant_number, nfc_uid, wall_ms, trusted_ms, elapsed_at, boot_count}`; `participant_number` — **глобальный** номер участника; `id` (клиентский UUID) — ключ идемпотентности; response `{accepted: [String]}`.
- **Пути**: `/app/login/`, `/app/logout/`, `/app/race/<id>/judge_scans/`, `/app/race/<id>/tags/` — все с trailing slash (он в подписанном canonical).
- **bindTag статусы**: 201 свежий bind / 200 идемпотентный повтор того же КП / 409 чип на **другом** КП (авто-ребинда нет — только веб-админка) / 404 КП нет или type hidden / 401 → `onUnauthorized()` + выход в логин / 429 (60/min/IP).
- **ProvisionState**: `waitingForChip → binding(uid) → waitingForWrite(uid:code:) → success(number) | failed(reason)`; `waitingForWrite` — новое состояние двухтапового флоу. Плохой hex-код от сервера → «Неверный код от сервера»; ошибка записи/read-back → «Не удалось записать, приложите снова» (состояние остаётся `waitingForWrite` — повтор безопасен, header-last).
- **Порядок веток классификаторов — 1:1 с Kotlin** (это спецификация): judge — poolNotReady → recorded → kpChip → unknownChip; КП-чек — noCode → unknownChip → inconsistent → ok; браслет — ok → kpChip → unknown.
- **Дрейн judge_scans**: ключ — `raceId` (`Int`), не `TrackScope`; Local → Cloud, независимо; батч 500; `markUploaded*` без version-guard (write-once); no-progress → `.error`; `outcomes: [Int: [UploadTarget: TargetUploadOutcome]]` + `outcomeUpdates`.
- **Grep-инварианты (расширение)**: `import Security` только под `Keychain/` (новая платформенная папка); `Core/Admin/` и `Core/Stores/` — по-прежнему Foundation-only; админ-модели `App/` — только `Observation`/`Foundation`; `import CoreNFC` по-прежнему только под `Nfc/`.

## What Goes Where

- **Implementation Steps** (`[ ]`): код, тесты, документация в этом репозитории.
- **Post-Completion** (без чекбоксов): ручная проверка на устройстве (NFC не работает в симуляторе), против живого сервера и реальных NTAG-чипов.

## Implementation Steps

### Task 1: Core — AdminTokenStore (Keychain, один JSON-item)

**Files:**
- Create: `kolco24/Core/Stores/AdminTokenStore.swift`
- Create: `kolco24/Keychain/AdminTokenStoreKeychain.swift`
- Create: `kolco24Tests/Core/AdminTokenStoreTests.swift`

- [x] `struct StoredAdminSession: Equatable, Codable { token, email, expiresAt: String }`; ядро `AdminTokenStore` на замыканиях `load: () -> Data?` / `save: (Data?) -> Void`; `read() -> StoredAdminSession?` (nil при отсутствии/битом JSON/пустом любом поле), `write(_:)`, `clear()` — `Core/Stores/` остаётся Foundation-only
- [x] прод-адаптер `AdminTokenStore.fromKeychain()` в **новой платформенной папке `Keychain/`** (прецедент `Nfc/`/`Location/`/`Audio/`) — `kSecClassGenericPassword`, service `kolco24.admin`, add/update/delete через `SecItem*`; **единственное** место `import Security` (grep-инвариант); папка авто-джойнится в таргет (synchronized group)
- [x] зеркало `AdminTokenStoreTest.kt` → `AdminTokenStoreTests` на in-memory load/save (round-trip write/read/clear; nil при отсутствии любого поля; pre-seeded store читается)
- [x] свежие кейсы: битый JSON → nil; `write` поверх старого item заменяет целиком
- [x] run tests - must pass before next task

### Task 2: Core — AdminSession + AdminSessionHolder

**Files:**
- Create: `kolco24/Core/Admin/AdminSession.swift`
- Create: `kolco24/Core/Admin/AdminSessionHolder.swift`
- Create: `kolco24Tests/Core/AdminSessionTests.swift`
- Create: `kolco24Tests/Core/AdminSessionHolderTests.swift`

- [x] `enum AdminSession: Equatable { case loggedOut, loggedIn(email: String, token: String, expiresAt: String) }`
- [x] `isExpired(expiresAt: String, nowUtcIso: String) -> Bool` — лексикографическое `nowUtcIso >= expiresAt` (граница = истёк); хелпер `nowUtcIso(_ date:)` — форматирование `yyyy-MM-dd'T'HH:mm:ss'Z'` UTC
- [x] `enum LoginOutcome: Equatable { success, invalidCredentials, rateLimited, offline, error }` + `loginOutcome(_ result: PostResult<...>)`-маппинг живёт в репозитории (Task 4 — `Core/` не видит `Net/`); в Core — `adminErrorMessage(_ outcome:) -> String?` (русские строки, success → nil)
- [x] `AdminSessionHolder` — идиома `LeaseHolder`: `final class @unchecked Sendable`, `NSLock`; sync `var session: AdminSession` + sync `var token: String?` (nil при loggedOut — читает `tokenProvider`); `set(_:)` — дедуп равных + публикация; `nonisolated let updates: AsyncStream<AdminSession>` (`.bufferingNewest(1)`, seed текущим значением)
- [x] сид-логика `seed(store:nowUtcIso:)`: сохранённая сессия с протухшим `expiresAt` → `store.clear()` + `.loggedOut`; живая → `.loggedIn` (deviation: в Android `seedSession` живёт в репозитории — на iOS сид переезжает в holder, чтобы `AppEnvironment` мог посидировать сессию **до** создания клиентов/репозитория)
- [x] зеркало `AdminAuthRepositoryTest.kt` (**только** часть isExpired/seed/errorMessage — остальные кейсы этого файла зеркалятся в Task 4) → `AdminSessionTests` (past/future/**boundary=expired**; seed протухшей → loggedOut + clear; живой → loggedIn; пустой стор → loggedOut) + `adminErrorMessage`-маппинг
- [x] свежие `AdminSessionHolderTests` (sync token при loggedIn/loggedOut; стрим публикует изменения, дедупит равные, seed первым кадром)
- [x] run tests - must pass before next task

### Task 3: Net — AuthDtos + ApiClient.login/logout + bearer

**Files:**
- Create: `kolco24/Net/Dto/AuthDtos.swift`
- Modify: `kolco24/Net/ApiClient.swift`
- Modify: `kolco24Tests/Net/SigningTests.swift` (или соседний ApiClient-тестфайл)
- Modify: `kolco24Tests/Net/ApiClientTests.swift`

- [x] `LoginRequest{email, password}` (Encodable), `LoginResponse{token, expires_at → expiresAt}` (Decodable, unknown keys игнорируются)
- [x] `ApiClient.login(email:password:) async -> PostResult<LoginResponse>` — generic `post` (тело сериализуется один раз, те же байты в подпись и в сеть, **без ретраев**), путь `/app/login/`
- [x] `ApiClient.logout() async -> PostResult<Void>` — POST с пустым телом (`EMPTY_BODY_SHA256`), путь `/app/logout/`; bearer уйдёт из `tokenProvider`
- [x] зеркало `SigningTest.kt` bearer-кейсов: `tokenProvider` non-nil → заголовок `Authorization: Bearer tok-123` есть; nil → заголовка нет; canonical-строка **не меняется** от наличия токена (добавлен `bearerDoesNotChangeSignature`; header-кейсы уже были)
- [x] зеркало `ApiClientTest.kt`: login 200 парсит token/expires_at и постит credentials (по `FakeTransport`-логу); 401 → `.unauthorized`; 429 → `.rateLimited`; logout пустое тело → 200 `.success`
- [x] run tests - must pass before next task

### Task 4: Data — AdminAuthRepository + композиция tokenProvider

**Files:**
- Create: `kolco24/Data/Repositories/AdminAuthRepository.swift`
- Modify: `kolco24/App/AppEnvironment.swift`
- Create: `kolco24Tests/Data/Repositories/AdminAuthRepositoryTests.swift`

- [ ] `struct AdminAuthRepository` (оперирует `PostResult` — прецедент stage-3; GRDB не нужен): deps — `login/logout`-замыкания к `ApiClient` (cloud), `store: AdminTokenStore`, `holder: AdminSessionHolder`, `nowUtcIso: () -> String`
- [ ] `login(email:password:) async -> LoginOutcome`: маппинг `PostResult → LoginOutcome`; success → `store.write` + `holder.set(.loggedIn)`; неуспех сессию **не трогает**
- [ ] `logout() async`: best-effort `apiClient.logout()`, но `store.clear()` + `holder.set(.loggedOut)` **всегда** (даже оффлайн/ошибка)
- [ ] `onUnauthorized()`: `store.clear()` + `.loggedOut` (вызовет провижининг при 401)
- [ ] `AppEnvironment`: `let adminSessionHolder` (сид из `AdminTokenStore.fromKeychain()`; `inMemory` — изолированный in-memory load/save, Keychain в тестах не трогается) — строится **до** `ApiClients.makeDefaultPair()`; оба клиента (cloud + LAN) получают `tokenProvider = { adminSessionHolder.token }`; `let adminAuthRepository` — после клиентов
- [ ] зеркало `AdminAuthRepositoryTest.kt` → `AdminAuthRepositoryTests` (`FakeTransport`): login success персистит + обновляет holder; 401/429/offline не персистят и не трогают сессию; logout чистит локально при серверном успехе **и** при оффлайне; `onUnauthorized` чистит; сид с протухшим expiry → loggedOut + пустой стор
- [ ] run tests - must pass before next task

### Task 5: Nfc — обобщение сканера (per-tag обработчик)

**Files:**
- Modify: `kolco24/Nfc/NfcChipScanner.swift`
- Modify: `kolco24/Core/Scan/ChipScanning.swift` (при необходимости — новые протокольные шовчики)

- [ ] вынести шаг «что сделать с подключённым тегом» в инжектируемый обработчик `process: (NfcTransport, _ uid: String, _ sample: TimeSample) -> TagReading` (выполняется на `readQueue`); session-менеджмент (restart через `shouldRestart`, ~1.5 с debounce по UID, `setStatus`, `sampleNow` **до** чтения, deadlock-дисциплина) не меняется
- [ ] дефолтный обработчик = текущее поведение (`readRecord` → `TagReading`); публичный интерфейс `ChipScanning` и все существующие вызовы (`ScanModel`, `TeamModel`) — без изменений
- [ ] pending-write ячейка для провижининга: thread-safe (`NSLock`) `setPendingWrite(uid: String, record: Data)` / `clearPendingWrite()` — ячейка живёт в сканере, но читает её **только инжектированный обработчик** (один механизм, не два): при совпадении uid выполняет `writeRecord(transport, record:)` + read-back и отдаёт результат в стрим. `TagReading` расширяется полем `writeResult: ChipWriteResult?` **с дефолтом `nil` в init** — существующие construction-sites (`FakeChipScanner`, `ScanModelTests`) не меняются
- [ ] несовпадающий uid при pending-write → обычное чтение + `writeResult = nil` (модель покажет «Приложите тот же чип»)
- [ ] прогнать **существующие** `ScanModelTests`/`TeamModelTests` — рефакторинг не должен их менять; новые unit-тесты на адаптер не пишутся (device-only, прецедент этапа 5) — записывающая логика уже покрыта `writeRecord`-тестами этапа 1, поведение хоста покроют `ProvisioningModelTests` (Task 11)
- [ ] run tests - must pass before next task

### Task 6: Core — JudgeScanLogic (классификатор + конструктор строки)

**Files:**
- Create: `kolco24/Core/Admin/JudgeScanLogic.swift`
- Create: `kolco24Tests/Core/JudgeScanLogicTests.swift`

- [ ] `enum JudgeScanResult: Equatable { poolNotReady, recorded(uid: String, number: Int), kpChip, unknownChip(uid: String) }`
- [ ] `classifyJudgeScan(uid:memberNumber:hasKpCode:poolReady:) -> JudgeScanResult` — порядок веток 1:1: `!poolReady` → `.poolNotReady`; матч в пуле → `.recorded`; `hasKpCode` → `.kpChip`; иначе `.unknownChip`. **Только `.recorded` пишет строку**
- [ ] `makeJudgeScan(id:raceId:eventType:participantNumber:nfcUid:sample:sourceInstallId:) -> JudgeScan` — идиома `makeKpTakeMark` (UUID и `TimeSample` параметрами): `takenAt = sample.wallMs`, `trustedTakenAt`/`elapsedRealtimeAt`/`bootCount` из сэмпла, флаги false
- [ ] зеркало `JudgeScanModelTest.kt` → `JudgeScanLogicTests` (5 кейсов: poolNotReady короткое замыкание даже при матче / даже при KP-коде; матч → recorded; матч побеждает KP-код; not-in-pool + KP → kpChip; not-in-pool + noCode → unknownChip) + свежие на `makeJudgeScan`-маппинг полей (вкл. nil trusted/boot)
- [ ] run tests - must pass before next task

### Task 7: Net+Data — judge_scans DTO, эндпоинт, дрейн-репозиторий

**Files:**
- Create: `kolco24/Net/Dto/JudgeScanUpload.swift`
- Modify: `kolco24/Net/ApiClient.swift`
- Create: `kolco24/Data/Repositories/JudgeScanUploadRepository.swift`
- Create: `kolco24Tests/Net/JudgeScanDtoTests.swift`
- Modify: `kolco24Tests/Net/ApiClientTests.swift`
- Create: `kolco24Tests/Data/Repositories/JudgeScanUploadRepositoryTests.swift`

- [ ] `JudgeScanUploadRequest{source_install_id, scans}` (**без `team_id`**), `JudgeScanDto` с ренеймами `wall_ms←takenAt`/`trusted_ms←trustedTakenAt`/`elapsed_at←elapsedRealtimeAt` и ручным `encode(to:)` (nullable-правило этапа 6: `trusted_ms`/`boot_count` — явный `null`), `init(from scan: JudgeScan)`; `JudgeScanUploadResponse{accepted}`
- [ ] `ApiClient.uploadJudgeScans(raceId:sourceInstallId:scans:) async -> PostResult<JudgeScanUploadResponse>` — generic `post`, trailing-slash путь `/app/race/<id>/judge_scans/`, **без ретраев**
- [ ] `actor JudgeScanUploadRepository` — структурный клон `TrackUploadRepository`: `inFlight`-tryLock, `uploadPending(raceId:)`, `uploadAllPending()` по `pendingUploadRaces()`, `flushRace` = Local → Cloud независимо через общий `drainUploadLoop` (fetch = `unuploadedLocal/Cloud(raceId:limit: uploadBatch)`, mark = `markUploadedLocal/Cloud(ids:)` — **без** version-guard, write-once); ключ outcomes — `raceId: Int`; `outcomes` + `nonisolated outcomeUpdates` (`.bufferingNewest(1)`); `wallNow` инжектируется
- [ ] зеркало `JudgeScanDtoTest.kt` → `JudgeScanDtoTests` (маппинг всех полей; null trusted/boot проходят явным null; snake_case ключи в JSON; парсинг `accepted`); дополнение `ApiClientTests` (uploadJudgeScans: путь/тело по `FakeTransport`-логу, статус-маппинг)
- [ ] зеркало `JudgeScanRepositoryTest.kt` → `JudgeScanUploadRepositoryTests` (in-memory БД + `FakeTransport`): accepted-subset маркирует только принятые; offline/error оставляет pending; дуал-таргет независимость (Local падает — Cloud дренится); no-progress → `.error`; reentrant при held-lock — no-op; `uploadAllPending` обходит все pending-гонки; outcome-callback не срабатывает, когда нечего слать
- [ ] run tests - must pass before next task

### Task 8: App — JudgeScanModel + триггеры дрейна + UploadModel-секция

**Files:**
- Create: `kolco24/App/JudgeScanModel.swift`
- Modify: `kolco24/App/AppModel.swift`
- Modify: `kolco24/App/AppEnvironment.swift`
- Modify: `kolco24/App/UploadModel.swift`
- Create: `kolco24Tests/App/JudgeScanModelTests.swift`
- Modify: `kolco24Tests/App/UploadModelTests.swift`

- [ ] `AppEnvironment`: `let judgeScanUploadRepository` (после клиентов); `AppModel.makeJudgeScanModel(eventType:)` — nil без выбранной команды (raceId = гонка команды); расширить 5-мин цикл и team-change flush на `judgeScanUploadRepository.uploadAllPending()`
- [ ] `@Observable @MainActor JudgeScanModel` (только `Observation`/`Foundation`): `for await` по стриму сканера; пул `member_tags` (подписка `memberTagStore.observeForRace`) + `hasBeenSynced`-гейт — синхронизированный-но-пустой ≠ «не синхронизирован»; при пустом несинхронизированном — inline `refreshMemberTags` (идиома bind-флоу этапа 5, «Синхронизируйте гонку» при неуспехе); сканы игнорируются до первой эмиссии пула (null-sentinel)
- [ ] обработка reading: `classifyJudgeScan` → `.recorded` → `makeJudgeScan` → `judgeScanStore.insert` в unstructured `Task` с захватом **стора** (§6) + fire-and-forget `uploadPending(raceId)` в том же Task; фидбек `ScanFeedbackPlaying` (success для recorded, failure для kpChip/unknown); лента последних 20 (`[JudgeScanResult]` со временем)
- [ ] 60-сек drain-цикл, пока экран открыт: `Task` с `Task.sleep`, стартует в `start()`, отменяется в `stop()`; `stop()` также финальный flush (fire-and-forget, захват репозитория) + `scanner.stop()`
- [ ] `UploadModel`: подписка `judgeScanStore.uploadCounts(raceId:)` + seed/стрим `judgeScanUploadRepository.outcomeUpdates` → счётчики/receipt-строки секции «Судейские отметки» (правила как у «Трек»: «Интернет» всегда при ненуле, «Финиш» при outcome/uploaded>0; секция скрыта при нуле); `pendingLabel` учитывает судейские строки
- [ ] свежие `JudgeScanModelTests` (in-memory БД + `FakeChipScanner` + `FakeTransport`): recorded пишет строку с полями сэмпла и триггерит upload (по логу транспорта); kpChip/unknown не пишут; poolNotReady при пустом несинхронизированном пуле + inline refresh по логу; лента капится 20; stop отменяет цикл
- [ ] дополнение `UploadModelTests`: счётчики/скрытие секции при нуле
- [ ] run tests - must pass before next task

### Task 9: UI — AdminFlowView (вход, логин, меню) + JudgeScanView

**Files:**
- Create: `kolco24/AdminFlowView.swift` (+ `AdminHomeView` внутри)
- Create: `kolco24/JudgeScanView.swift`
- Modify: `kolco24/SettingsView.swift`
- Modify: `kolco24/App/SettingsModel.swift` (сабтайтл ряда)
- Modify: `kolco24/UploadView.swift`

- [ ] ряд «Администратор» в `SettingsView` (секция над «О приложении», всегда видимый; сабтайтл «Войти» / email из `AdminSessionHolder`-стрима через `SettingsModel`) → закрыть шит → `fullScreenCover` с `AdminFlowView` (прецедент `TeamPickerFlowView`)
- [ ] `AdminFlowView`: `NavigationStack`; корень `AdminHomeView` ветвится по сессии (подписка на `adminSessionHolder.updates`): `loggedOut` → форма (email/пароль, «Войти», спиннер, inline-ошибка из `adminErrorMessage`; submit → `adminAuthRepository.login` в unstructured Task); `loggedIn` → email + ряды «Привязать чип к КП» / «Проверить чип КП» / «Проверить чип участника» / «Отметка старта» / «Отметка финиша» / «Выйти» (logout в unstructured Task); без выбранной команды — подсказка вместо рядов (raceId неизвестен)
- [ ] `JudgeScanView(model:)`: заголовок «Отметка старта»/«Отметка финиша», крупные живые часы (локальная TZ, `Font.mono`), статус последнего скана (зелёный `№N` / amber «Это чип КП» / красный «Неизвестный чип» + uid), лента недавних (до 20), плейт «Синхронизируйте гонку» при несинхронизированном пуле; `.task` — `start()` (сканер + permission-хуки не нужны, NFC-шторка системная); `onDisappear`/dismiss → `stop()`
- [ ] `UploadView`: секция «Судейские отметки» по `UploadModel` (стиль/правила секции «Трек»)
- [ ] дизайн-токены/компоненты проекта (`Color.card`, `SectionHeader`, `MiscRowView`-паттерн, `Font.mono`); превью на `FakeChipScanner`
- [ ] прогон полного сьюта + сборка (UI-задача — hard gate не ослабляется)
- [ ] run tests - must pass before next task

### Task 10: Core+App+UI — проверки чипов (КП и браслет, read-only)

**Files:**
- Create: `kolco24/Core/Admin/ChipCheckLogic.swift`
- Create: `kolco24/App/ChipCheckModel.swift`
- Create: `kolco24/App/MemberChipCheckModel.swift`
- Create: `kolco24/CheckChipView.swift`
- Create: `kolco24/CheckMemberChipView.swift`
- Modify: `kolco24/AdminFlowView.swift` (навигация)
- Modify: `kolco24/App/AppModel.swift` (фабрики)
- Create: `kolco24Tests/Core/ChipCheckLogicTests.swift`
- Create: `kolco24Tests/Core/MemberChipCheckLogicTests.swift`
- Create: `kolco24Tests/App/ChipCheckModelTests.swift`

- [ ] `classifyChipCheck(uid:bid:tag:checkpoint:chipsOnKp:) -> ChipCheckResult` (`noCode(uid)` / `unknownChip(uid,bid)` / `inconsistent(uid,bid,checkpointId)` / `ok(uid,number,cost,color,bid,checkMethod,chipsOnKp)`) — порядок веток 1:1; полностью оффлайн, `bid = LegendCrypto.bid(code)`, **без** дешифровки и без `reveal`-сайд-эффекта
- [ ] `classifyMemberChipCheck(uid:memberNumber:hasKpCode:) -> MemberChipCheckResult` (`ok(uid,number)` / `kpChip(uid)` / `unknown(uid)`) — UID-only матч, код — лишь диагностика
- [ ] `changedNibbles(uid:previous:) -> Set<Int>` — позиции отличий от предыдущего скана (пусто без базы)
- [ ] `ChipCheckModel` (подписки `tagStore`/`checkpointStore` для гонки, null-sentinel «игнор до первой эмиссии», счётчик «чипов на этом КП» из `tags`) и `MemberChipCheckModel` (подписка `memberTagStore`, размер пула для idle-строки) — оба transient (без персиста), лента 20, тот же K24-стрим сканера; фабрики `AppModel.makeChipCheckModel()`/`makeMemberChipCheckModel()`
- [ ] `CheckChipView` («Проверка чипов КП»): hero — номер КП + стоимость (`pointsWord`) + цветовая полоса + `bid · checkMethod` + «На этом КП ещё N чипов» + UID с diff-подсветкой (`changedNibbles`); amber/red герои для noCode/unknown/inconsistent. `CheckMemberChipView` («Проверка браслетов»): `№N` + зелёная галка / amber «Это чип КП» / красный «Неизвестный чип»; idle-строка с размером пула (0 — признак «не синхронизирован»)
- [ ] зеркала `ChipCheckModelTest.kt`/`MemberChipCheckModelTest.kt` → `ChipCheckLogicTests`/`MemberChipCheckLogicTests` (ok при tag+cp; nullBid → noCode; нет тега → unknownChip; тег без чекпойнта → inconsistent; незнакомый цвет → nil; locked → ok с nil cost; changedNibbles-варианты; браслет: пул побеждает KP-код, kpChip, unknown)
- [ ] свежие `ChipCheckModelTests` (обе модели: сканы до эмиссии пула игнорируются; лента капится)
- [ ] run tests - must pass before next task

### Task 11: Net+Core — bindTag + ProvisioningLogic

**Files:**
- Create: `kolco24/Net/Dto/TagBind.swift`
- Modify: `kolco24/Net/ApiClient.swift`
- Create: `kolco24/Core/Admin/ProvisioningLogic.swift`
- Modify: `kolco24Tests/Net/ApiClientTests.swift`
- Create: `kolco24Tests/Core/ProvisioningLogicTests.swift`

- [ ] `TagBindRequest{checkpoint_id, nfc_uid}` (стабильный `Checkpoint.id`, **не** человеческий номер), `TagBindResponse{bid, checkpoint_id, number, nfc_uid, code}`; `ApiClient.bindTag(raceId:checkpointId:nfcUid:) async -> PostResult<TagBindResponse>` — trailing-slash `/app/race/<id>/tags/`, без ретраев; вызывается на **cloud-клиенте** (как login/logout — админ-операции не ходят на LAN)
- [ ] `enum ProvisionState: Equatable { waitingForChip, binding(uid), waitingForWrite(uid: String, code: String), success(number: Int), failed(reason: String) }`
- [ ] `provisionErrorMessage(_ result:) -> String` — русские строки 1:1 (409 generic «уже привязан к другому КП» — тело ответа номера КП не несёт; 403 «Нет прав администратора… или ошибка подписи/часов»; 401 «Сессия истекла, войдите снова»; 404 «КП не найдено»; offline/прочие)
- [ ] `chipTokenLabel(uid:) -> String` — последние 4 hex-символа
- [ ] зеркало `ApiClientTest.kt` bindTag-кейсов (201 парсит `code`; 200 идемпотентный; 409 → `.conflict`; 404; тело запроса по `FakeTransport`-логу) и `ProvisioningModelTest.kt` → `ProvisioningLogicTests` (`provisionErrorMessage` по каждому статусу; `chipTokenLabel` tail/короткий/5-символьный; `railTicks` — **не портируется**, пейджер заменён списком)
- [ ] run tests - must pass before next task

### Task 12: App+UI — ProvisioningModel + ProvisioningView (двухтаповый флоу)

**Files:**
- Create: `kolco24/App/ProvisioningModel.swift`
- Create: `kolco24/ProvisioningView.swift`
- Modify: `kolco24/AdminFlowView.swift` (навигация)
- Modify: `kolco24/App/AppModel.swift` (фабрика)
- Create: `kolco24Tests/App/ProvisioningModelTests.swift`

- [ ] `@Observable @MainActor ProvisioningModel`: список КП гонки (подписка `checkpointStore`) + счётчики «уже привязано» из `tagStore` + свежие за сессию (per-КП uid-множества; max/subtract-логика против двойного счёта после mid-session legend refresh); выбранный КП (автопереход к следующему после success)
- [ ] флоу: тап 1 (reading при `waitingForChip`) → `binding(uid)` → `bindTag(raceId, cp.id, uid)` в unstructured Task (§6); success → `chipCodeFromHex(code)` (битый hex → `failed("Неверный код от сервера")`) → `buildChipRecord` → `scanner.setPendingWrite(uid:record:)` → `waitingForWrite` «Приложите чип ещё раз»; 401 → `adminAuthRepository.onUnauthorized()` + закрытие в логин; прочие ошибки → `failed(provisionErrorMessage)`
- [ ] тап 2: reading с `writeResult` → success → `success(number)` + фидбек/fanfare-мотив + автопереход; `failed`/read-back mismatch → «Не удалось записать, приложите снова» (остаёмся `waitingForWrite`, pending-write сохранён — повтор безопасен, header-last); чужой uid → подсказка «Приложите тот же чип», без записи
- [ ] `ProvisioningView` («Привязка чипов»): список/степпер КП (моно-номер + стоимость + цветовая полоса + «Уже привязано: N» + зелёные пилюли свежих `chipTokenLabel`), hero выбранного КП, зона сканирования со статусом `ProvisionState`; смена КП сбрасывает pending-write
- [ ] свежие `ProvisioningModelTests` (in-memory БД + `FakeChipScanner` + `FakeTransport`): happy path тап1→bind→pending-write→тап2→success; 409/404/403 → failed с верной строкой; 401 → onUnauthorized (holder → loggedOut); битый hex → «Неверный код от сервера»; write-fail оставляет waitingForWrite; свежая пилюля не даёт двойного счёта после рефреша легенды
- [ ] run tests - must pass before next task

### Task 13: Верификация приёмки

- [ ] пройтись по Overview: логин/логаут/протухание/401-разлогин; судейский скан пишет только recorded + дрейн по всем 4 триггерам; обе проверки оффлайн и read-only; провижининг двухтаповый со сверкой uid — всё реализовано
- [ ] grep-инварианты: `import Security` только под `Keychain/`; `Core/Admin/` и `Core/Stores/` — Foundation-only; админ-модели `App/` — только `Observation`/`Foundation`; `import CoreNFC` только под `Nfc/`; `import GRDB` не появился вне `Data/`
- [ ] edge cases: bearer не в canonical (подпись не зависит от токена); судейский скан при пустом синхронизированном пуле не показывает «синхронизируйте»; повторный тап 2 после write-fail работает; закрытие экранов не рвёт insert/bind (unstructured Task)
- [ ] полный сьют: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'`
- [ ] сборка: `xcodebuild -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16' build`

### Task 14: [Final] Документация

- [ ] обновить `CLAUDE.md`: новый раздел «Admin layer» (Keychain-стор, sessia/holder, bearer-wiring, судейский дрейн, NFC-обобщение, двухтаповый провижининг, deviations, grep-инварианты, known fact про judge_scans-эндпоинт)
- [ ] обновить `docs/plans/android-port.md`: этап 10 → ✅ со ссылкой на этот план; «Инфо о чипе» (GET_VERSION) помечено «не портируется» (решение при планировании)
- [ ] переместить этот план в `docs/plans/completed/`

## Post-Completion

**Ручная проверка (живой сервер):**
- логин реальными admin-креденшалами → 200, меню открывается; неверный пароль → «Неверный email или пароль»; логаут; перезапуск приложения при живом токене → сразу меню (Keychain)
- best-effort live-smoke по образцу `LiveServerSmokeTests` (login против боевого сервера), gate не блокирует

**Ручная проверка (устройство, NFC в симуляторе не работает):**
- судейский скан: браслет из пула → зелёный `№N` + строка в «Загрузка данных» (pending — эндпоинт не задеплоен, это норма); КП-чип → amber; неизвестный чип → красный
- проверка КП-чипа: привязанный чип → номер/стоимость/цвет/bid; чужой → «неизвестный»; браслет-проверка → `№N`
- **провижининг на реальных NTAG213/215/216 (самая рискованная фича)**: тап 1 → bind → «приложите ещё раз» → тап 2 → запись + read-back → success; отрыв чипа во время записи → повтор тапа 2 дописывает (header-last); чужой чип на тапе 2 → отказ; 409 на чипе с другого КП; проверить записанный чип обычным сканом взятия
- 401 посреди провижининга (отозвать токен на сервере) → выход в логин-форму

**Известный факт:** судейские строки останутся pending до деплоя серверного эндпоинта `/judge_scans/` — self-heal дошлёт их той же сборкой (как это было с `/marks/`).
