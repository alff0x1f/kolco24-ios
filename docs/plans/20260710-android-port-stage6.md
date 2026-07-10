# Этап 6 портирования: загрузка данных на сервер (выгрузка взятий)

Детализация этапа 6 из [android-port.md](android-port.md). Этапы 0–5 выполнены: чистая логика, GRDB-слой, сеть/sync-репозитории, `@Observable`-модели и живой NFC-скан-флоу готовы и покрыты тестами. Взятия пишутся в БД с флагами `uploadedLocal/uploadedCloud = 0` — этап 6 доставляет их на сервер.

## Overview

Этап 6 делает приложение «боевым» (MVP-граница мастер-плана): накопленные взятия (`marks`) идемпотентно выгружаются батчами на **обе цели** — облако (HTTPS) и локальный сервер события (LAN) — с независимыми флагами `uploadedLocal`/`uploadedCloud`, self-heal при офлайне/ошибках, плюс экран «Загрузка данных» со счётчиками и принудительной отправкой.

**Ключевые решения брейншторма (адаптация под платформу, не 1в1 из Kotlin):**
- **Скоуп: только marks + переиспользуемый движок.** Track (этап 8), фото-кадры (этап 7) и judge_scans (этап 10) добавят свои дрейны поверх готового generic-цикла — мёртвые циклы сейчас не пишем. Исключение — `combineOutcome` (5 строк, часть той же спеки `TrackModels.kt`): портируется сейчас под этап 7.
- **Обе цели сразу.** Как на Android: каждый триггер пробует облако и LAN независимо. Вне сети события LAN-клиент (таймаут 3 с, уже собран — `ApiClients.makeLocal`) быстро фейлится в `.offline`, флаг остаётся `0` — самовосстановление без этапа 9.
- **`actor MarkUploadRepository`** вместо Kotlin `Mutex.tryLock()`: изоляция актора + флаг `inFlight` — перекрывающиеся триггеры молча пропускают (тот же приём, что `TrustedClock`). Исходы выгрузки — словарь в акторе + `AsyncStream` (идиома `statusUpdates`).
- **UI**: ряд «Загрузка данных» в TeamView (подзаголовок — счётчик неотправленного) → шит `UploadView`; **pull-to-refresh и есть принудительная отправка** (отдельной кнопки нет, как на Android).

Вне скоупа: BGTaskScheduler / фоновая выгрузка (мастер-план: «опционально позже»), дрейны track/judge/фото, LAN-lease (этап 9).

**Известный факт, не баг:** бэкенд-эндпоинт `/app/race/<id>/marks/` ещё **не реализован** на сервере (UPLOAD.md: «клиент реализован, ждёт backend»). Живая проверка покажет вечное «ошибка»/pending — это спроектированный self-heal (`404`/`403` оставляют флаг `0`, дошлётся, когда эндпоинт поднимут). Hard gate этапа — зелёный локальный тест-сьют + сборка.

## Context (from discovery)

**Уже готово и переиспользуется (не переписывать):**
- `Data/Stores/MarkStore.swift` — весь DB-слой дренажа: `unuploadedLocal/Cloud(raceId:teamId:limit:)` (ORDER BY `COALESCE(trustedTakenAt, takenAt), id`), version-guarded `markUploaded{Local,Cloud}IfUnchanged(id:updatedAt:)` и `…IfUnchangedAndNoLocation` (второй ортогональный guard `locLat IS NULL` — поздний `attachLocation` не теряется), агрегаты `uploadCounts`/`uploadCountsMetadata` (observation), `pendingUploadScopes()`; `UploadTypes.swift` (`UploadCounts`, `TrackScope` — `Hashable`, годится ключом исходов).
- `Net/ApiClient.swift` — generic `post(url:body:contentType:parse:) async -> PostResult<T>`: подпись 6 заголовков, тело сериализуется один раз (те же байты в хэш подписи и в отправку), **никогда не ретраится** (403 auth-vs-skew неразличим), `URLError → .offline`. `endpoint(_:)` со слэшем в конце (слэш — в подписанном каноне).
- `Net/ApiResults.swift` — `PostResult` (`success/badRequest/unauthorized/forbidden/conflict/rateLimited/offline/error(code:)`).
- `Net/URLSessionTransport.swift` — `ApiClients.makeDefaultPair()`: cloud (10 с) + local (3 с) поверх общих `TrustedClock`/`InstallId`.
- `App/AppEnvironment.swift` — композиционный корень со сторами и репозиториями. **Внимание:** cloud/local `ApiClient`-ы сейчас потребляются в `init` репозиториями и **не хранятся** как свойства, а `installId` в графе нет вовсе (`ApiClients.makeDefaultPair()` его не возвращает) — Task 4 протягивает их явно (`installId` доступен через публичное `ApiClient.installId` либо идемпотентный `InstallId.fromUserDefaults()`). `App/AppModel.swift` — `start()`, наблюдение выбранной команды (реагирует на смену — сюда встаёт flush), фабрики `makeXxxModel()`.
- `ScanSheet.swift:111` — `TODO(этап 6)`: hook flush-загрузки при закрытии оверлея (сейчас no-op).
- `Core/Util/PluralRu.swift` — `relativeTimeRu(atWallMs:nowMs:)` для второй строки receipt-лайна.
- `Model/Mark.swift` — все поля контракта уже есть (`present: [Int]`, `presentDetails: [MarkMemberSnapshot]?` с `nfcUid/number/code`, `trustedTakenAt/takenAt/elapsedRealtimeAt/bootCount`, 7 `loc*`-полей, `updatedAt` для version-guard).
- Тестовая конвенция: реальные сторы на `AppDatabase.makeInMemory()` + `FakeTransport` (лог запросов, программируемые ответы) — этапы 2–5.

**Kotlin-источники** (в `/Users/alff0x1f/src/kolco24_app_v2`, пакет `app/src/main/java/ru/kolco24/kolco24/`; контракт — `docs/design/UPLOAD.md`):
- `data/api/ApiClient.kt` — `uploadMarks(raceId, teamId, sourceInstallId, marks)` (L224–234): `POST /app/race/<raceId>/marks/`, тело `MarkUploadRequest(team_id, source_install_id, marks)`; ответ `{accepted: [id]}`.
- `data/api/dto/MarkDtos.kt` — `MarkDto` (snake_case поля L28–42; **ловушки маппинга**: `cp_nfc_uid ← cpUid`, `cp_code ← cpCode` — не прямой snake_case имён Swift-полей), `PresentMemberDto(nfc_uid, code, number, number_in_team)`, `TakeLocationDto(lat, lon, accuracy, altitude, vertical_accuracy, gps_time_ms, elapsed_at)`; **`MarkEntity.toDto()` (L90–128) — merge `present[]`**: итерация по `present` (скоринговая истина), обогащение из `presentDetails.associateBy { numberInTeam }`, при отсутствии снимка — sentinel `{nfc_uid: null, code: null, number: 0, number_in_team: num}`; `location` строится только когда `locLat != null && locLon != null`.
- `data/MarkRepository.kt` — `UPLOAD_BATCH = 500` (L482); `uploadMutex.tryLock` в `uploadPending`/`uploadAllPending` (L280–303, проигравший молча выходит); `flushScope` (L314–340): **сначала Local, потом Cloud**, исход в `onUploadOutcome`; **`uploadLoop` (L390–407)** — ядро: fetch батча → пустой и был прогресс → `Ok`, пустой без прогресса → `null`; не-`Success` → kind (`Offline`/`Error`); `accepted ∩ batchIds` пусто → `Error` (нет прогресса — защита от зацикливания); иначе mark + следующая итерация; GPS-aware marking (L355–378): `locLat != nil` → `IfUnchanged`, иначе → `IfUnchangedAndNoLocation`.
- `data/track/TrackModels.kt` (L79–98) — `UploadTarget{Local,Cloud}`, `UploadResultKind{Ok,Offline,Error}`, `TargetUploadOutcome(kind, atWallMs)`, `combineOutcome` (приоритет `Error > Offline > Ok > null`).
- Триггеры: `MainActivity.kt` L167/589–597 — 5-мин foreground-таймер (`repeatOnLifecycle(STARTED)`, срабатывает сразу при входе); `Kolco24App.kt` L84–99 — flush при смене выбранной команды (покрывает и старт приложения); `MainActivity.kt` L1311–1319 — flush при закрытии скан-оверлея; L1545–1561 — pull-to-refresh экрана как force-flush. 60-с judge-таймер не портируется (judge_scans — этап 10).
- Экран: `ui/upload/UploadScreen.kt` + `UploadStatusModels.kt` — секции по видам данных (у нас пока одна — «Отметки»), receipt-лайны: «Интернет» (cloud) всегда, «Финиш» (local) только когда `outcome != nil || uploaded > 0`; `uploaded/total` моноширинным; вторая строка `«{relativeTime} · {ok|нет интернета|сервер недоступен|ошибка}»` когда не done; done-глиф зелёный, error/offline — красный; empty state «Пока нечего загружать».
- **Android-тесты для зеркалирования:** `MarkDtoMappingTest.kt` (DTO-merge), `MarkRepositoryUploadTest.kt` (uploadLoop-поведение — отдельный файл, не `MarkRepositoryTest.kt`), `ApiClientMarksTest.kt` (эндпоинт) — имена кейсов переносить 1:1 где применимо; для актора/UploadModel зеркала нет — тесты свежие.

## Development Approach

- **testing approach**: порт-конвенция этапов 2–5 — Kotlin-тесты переносятся вместе с модулем в той же задаче (имена кейсов 1:1, header «Зеркало …»); для актор-специфики и `UploadModel` зеркала нет — тесты пишутся с нуля (regular: код → тесты в той же задаче) поверх реальных сторов на `AppDatabase.makeInMemory()` + `FakeTransport`;
- complete each task fully before moving to the next;
- make small, focused changes (коммит на задачу);
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task;
- **CRITICAL: all tests must pass before starting next task**;
- **CRITICAL: update this plan file when scope changes during implementation**.

## Testing Strategy

- **unit tests**: Swift Testing. `kolco24Tests/Core/UploadModelsTests` (чистая логика), `kolco24Tests/Net/MarkUploadDtoTests` (merge + JSON-имена полей), `kolco24Tests/Data/Repositories/MarkUploadRepositoryTests` (актор поверх in-memory БД + `FakeTransport` — поведенческая спека движка), `kolco24Tests/App/UploadModelTests` (`@MainActor`).
- **e2e**: автоматизированных нет; серверный эндпоинт ещё не поднят — сквозная проверка ограничена «строки остаются pending, исход виден на экране» (Post-Completion).
- Прогон: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'` (нужен `Config/Secrets.xcconfig`; при флаки-имени — `id=<UDID>` из `xcrun simctl list devices available`).

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview

Поток данных: триггер (таймер / смена команды / закрытие скан-оверлея / pull-to-refresh) → `MarkUploadRepository.uploadAllPending()` (актор, `inFlight`-guard) → по каждому скоупу из `pendingUploadScopes()`: для Local, затем Cloud — `drainUploadLoop` (fetch ≤500 → `ApiClient.uploadMarks` → mark `accepted ∩ batch` с GPS-aware version-guard → повтор) → исход `TargetUploadOutcome` в словарь актора → `AsyncStream` → `UploadModel` → `UploadView`.

Ключевые решения:
- **Generic `drainUploadLoop<Row>`** в файле репозитория (не в `Core/` — он оперирует `PostResult`, сетевым типом; прецедент — refresh-флоу этапа 3 живёт в `Data/Repositories/`). Этапы 8/10 переиспользуют его для track/judge.
- **Ошибки БД внутри дрейна** фолдятся в `.error` + лог (движок никогда не роняет процесс — конвенция «decode error → fallback + log» этапа 2).
- **Исходы** ключуются `TrackScope` → `[UploadTarget: TargetUploadOutcome]`; стрим отдаёт полный словарь-снимок (дедуп равных значений вручную, `.bufferingNewest(1)` — 1:1 идиома `TrustedClock.statusUpdates`).
- **Триггеры** живут в `AppModel` (UI-framework-free): 5-мин цикл — обычный `Task` со `Task.sleep`; аналог `repeatOnLifecycle(STARTED)` — `ContentView` наблюдает `\.scenePhase` и дёргает `appModel.scenePhaseChanged(isActive:)` (рестарт цикла на `.active` = немедленный fire, отмена на background).
- **`wallNow: () -> Int64`** инжектится в актор (метка `atWallMs` исходов) — управляемое время в тестах, идиома этапа 5.

## Technical Details

- Канон подписи/заголовков не меняется — `post` уже делает всё (тело хэшируется как есть, trailing slash в пути обязателен: `/app/race/\(raceId)/marks/`).
- `MarkUploadRequest` кодируется `JSONEncoder` c явными `CodingKeys` (конвенция GET-DTO; `.sortedKeys` не обязателен — подпись считается от готовых байт).
- Nullable-кодирование — как реально шлёт Android (kotlinx.serialization с `encodeDefaults = false`, `explicitNulls = true`): скаляры **без** default-значения (`trusted_ms`, `elapsed_at`, `boot_count`, `present[].nfc_uid`/`code`, все nullable-поля внутри `TakeLocationDto`) кодируются явным JSON `null` (в Swift — явный `encode`, не `encodeIfPresent`); а вот `location` в Kotlin имеет default `= null` и при отсутствии фикса **опускается целиком** (ключа нет) — в Swift для него `encodeIfPresent`.
- Ответ: `MarkUploadResponse { accepted: [String] }`; `PostResult<MarkUploadResponse>`.
- Маппинг `PostResult → UploadResultKind`: `.success` не доходит до маппинга (обрабатывается в цикле), `.offline → .offline`, всё прочее → `.error` (функция `uploadResultKind` в файле репозитория — зеркало `uploadResultKind` из `TrackModels.kt`).
- `drainUploadLoop` (эскиз; `upload` возвращает `PostResult<[String]>` — уже извлечённый `accepted`, а не конкретный response-DTO, чтобы track/judge-дрейны этапов 8/10 со своими `*UploadResponse` переиспользовали цикл без обобщения задним числом):
  ```swift
  func drainUploadLoop<Row>(
      fetch: () async throws -> [Row],
      id: (Row) -> String,
      upload: ([Row]) async -> PostResult<[String]>,
      mark: ([Row], Set<String>) async throws -> Void
  ) async -> UploadResultKind?
  ```
  Семантика 1:1 с `uploadLoop` L390–407 (включая различие `nil` «нечего было слать» vs `.ok` «слал и дослал»).
- `UPLOAD_BATCH = 500`, `UPLOAD_RETRY_INTERVAL_MS = 300_000` — константы репозитория/AppModel, имена как в Kotlin.
- Счётчик ряда в TeamView: `total - min(local, cloud)`… **нет** — Android показывает receipt-лайны по целям; для подзаголовка ряда достаточно «N не отправлено» = `total - cloud` (облако — главная цель; LAN вне гонки всегда 0 и пугал бы). Формулировка: `«N не отправлено» / «Всё отправлено» / «Пока нечего загружать»`.

## What Goes Where

- **Implementation Steps**: код, тесты, документация — всё проверяемо сборкой/сьютом в симуляторе.
- **Post-Completion**: живая проверка на устройстве против реального сервера (эндпоинт ещё не поднят — ожидания описаны), решения этапа 9 про LAN.

## Implementation Steps

### Task 1: Core/Upload — модели исходов выгрузки

**Files:**
- Create: `kolco24/Core/Upload/UploadModels.swift`
- Create: `kolco24Tests/Core/UploadModelsTests.swift`

- [x] `UploadTarget` (`local`/`cloud`), `UploadResultKind` (`ok`/`offline`/`error`), `TargetUploadOutcome { kind, atWallMs }` — зеркало `TrackModels.kt` L79–98; чистый Foundation, без framework-импортов
- [x] `combineOutcome(_:_:) -> UploadResultKind?` с приоритетом `error > offline > ok > nil` (задел этапа 7 — метаданные+кадры)
- [x] тесты: таблица приоритетов `combineOutcome` (все пары), `Equatable`-семантика `TargetUploadOutcome`
- [x] прогнать тесты — зелёные до Task 2

### Task 2: Net — upload-DTO с merge present[] и эндпоинт uploadMarks

**Files:**
- Create: `kolco24/Net/Dto/MarkUpload.swift`
- Modify: `kolco24/Net/ApiClient.swift`
- Create: `kolco24Tests/Net/MarkUploadDtoTests.swift`

- [x] `Encodable`-типы: `MarkUploadRequest{team_id, source_install_id, marks}`, `MarkDto`, `PresentMemberDto`, `TakeLocationDto` — snake_case `CodingKeys`, nullable-поля кодируются явным `null` (см. Technical Details); `Decodable` `MarkUploadResponse{accepted}`
- [x] `MarkDto(from: Mark)`: merge по `present` (истина состава) + `presentDetails.associateBy(numberInTeam)`; sentinel `{nil, nil, 0, num}` для отсутствующего снимка; `location` только при `locLat != nil && locLon != nil`; маппинг времён `trusted_ms ← trustedTakenAt`, `wall_ms ← takenAt`, `elapsed_at ← elapsedRealtimeAt`
- [x] `ApiClient.uploadMarks(raceId:teamId:sourceInstallId:marks:) async -> PostResult<MarkUploadResponse>` — `post` на `endpoint("/app/race/\(raceId)/marks/")`, тело сериализуется один раз
- [x] тесты merge (зеркало `MarkDtosTest`): обогащённый снимок, sentinel при частичном снимке, legacy `presentDetails == nil` → все sentinel, `location == nil`, полный `location`
- [x] тесты JSON-формы: точные имена ключей (снапшот-проверка по декоду в словарь, включая ловушки `cp_nfc_uid`/`cp_code`), `null`-ключи присутствуют у no-default скаляров, ключ `location` **отсутствует** при nil-фиксе, `team_id`/`source_install_id` на батче
- [x] тест эндпоинта через `FakeTransport`: метод POST, путь `/app/race/7/marks/` (со слэшем), `Content-Type: application/json`, парс `accepted`
- [x] прогнать тесты — зелёные до Task 3

### Task 3: Data/Repositories — actor MarkUploadRepository + drainUploadLoop

**Files:**
- Create: `kolco24/Data/Repositories/MarkUploadRepository.swift`
- Create: `kolco24Tests/Data/Repositories/MarkUploadRepositoryTests.swift`

- [x] generic `drainUploadLoop<Row>(fetch:id:upload:mark:) async -> UploadResultKind?` — семантика Kotlin `uploadLoop` L390–407: стоп на пустом fetch (`nil` без прогресса / `.ok` с прогрессом), не-success → kind, `accepted ∩ batch` пусто → `.error`; DB-ошибки → `.error` + лог
- [x] `actor MarkUploadRepository`: deps `markStore`, `cloud: ApiClient`, `local: ApiClient`, `installId: String`, `wallNow: () -> Int64`; `private var inFlight = false` — tryLock-аналог (guard-выход у обоих входов)
- [x] `uploadPending(raceId:teamId:)` и `uploadAllPending()` (обход `pendingUploadScopes()`); `flushScope`: Local → Cloud, каждый через `drainUploadLoop` с батчем 500 и GPS-aware marking (`locLat != nil` → `markUploaded*IfUnchanged`, иначе `…AndNoLocation`)
- [x] исходы: `outcomes: [TrackScope: [UploadTarget: TargetUploadOutcome]]` + `nonisolated outcomeUpdates: AsyncStream<[TrackScope: [UploadTarget: TargetUploadOutcome]]>` (`.bufferingNewest(1)`, дедуп равных снимков — идиома `TrustedClock.statusUpdates`); `uploadResultKind(PostResult) → UploadResultKind`
- [x] тесты (реальный `MarkStore` на in-memory БД + `FakeTransport`): happy path — оба таргета флипают флаги; partial accept — помечены только `accepted ∩ batch`; пустой `accepted` → стоп с `.error`, флаги нетронуты; `.offline` (URLError) → флаги 0, исход `.offline`; 403 → ровно один запрос в логе транспорта (нет ретрая), исход `.error`. **Ловушка `FakeTransport`:** это FIFO-очередь ответов по порядку вызовов, не роутинг по URL, а `inMemory` даёт cloud и local **один** транспорт — ответы энкьюить в порядке `flushScope` (сначала все Local-батчи, затем Cloud; при нескольких скоупах — в порядке `pendingUploadScopes()`)
- [x] тесты: >500 строк → батчирование (2+ запроса, все флаги в 1); version-guard — `addMember`/`attachLocation` после fetch, до mark → флаг остаётся 0 (строка перевыгрузится); конкурентные `uploadAllPending` → один проход по транспорт-логу; `uploadAllPending` обходит оба скоупа из `pendingUploadScopes()`; исход попадает в стрим
- [x] прогнать тесты — зелёные до Task 4

### Task 4: AppEnvironment + AppModel — граф и триггеры

**Files:**
- Modify: `kolco24/App/AppEnvironment.swift`
- Modify: `kolco24/App/AppModel.swift`
- Modify: `kolco24/ContentView.swift`
- Modify: `kolco24/ScanSheet.swift` (+ точка вызова в `MarksView.swift`, если hook прокидывается оттуда)
- Create/Modify: `kolco24Tests/App/AppModelUploadTests.swift` (или расширение существующих AppModel-тестов)

- [x] `AppEnvironment`: `let markUploadRepository: MarkUploadRepository` в прод-графе и в `inMemory(transport:)` (оба клиента поверх инжектированного транспорта — конвенция этапа 4). **Протянуть зависимости явно**: cloud/local `ApiClient`-ы сейчас потребляются в `init` и не хранятся, `installId` в графе нет (`makeDefaultPair()` его не возвращает) — взять из `pair.cloud.installId` (публичное свойство `ApiClient`) либо `InstallId.fromUserDefaults()` (идемпотентен)
- [x] `AppModel.start()`: 5-мин drain-`Task` (fire сразу, затем `Task.sleep(300_000 ms)`); `scenePhaseChanged(isActive:)` — рестарт цикла на active (немедленный fire), отмена на background; `ContentView` наблюдает `\.scenePhase` и пробрасывает
- [x] flush при смене команды: в существующем наблюдении `selectedTeamStore` — fire-and-forget `uploadAllPending()` (покрывает и старт: первая эмиссия выбранной команды)
- [x] `AppModel.flushUploads(raceId:teamId:)` — fire-and-forget `Task`, захватывающий репозиторий (не `self`) — закрытие шита не абортит выгрузку (§6-идиома этапа 5). **Конкретный шов** (у `ScanSheet` нет доступа к `AppModel` — только `ScanModel`): вызов из `MarksView`, где `AppModel` уже в `@Environment` и шит презентуется, — `.sheet(item:onDismiss:)` покрывает все пути закрытия; `TODO(этап 6)` в `ScanSheet.swift:111` удалить с отсылкой на новый шов
- [x] тесты (`FakeTransport`-лог): смена выбранной команды триггерит выгрузку pending-строки; `flushUploads` дренирует скоуп; инжектированный интервал/время — таймер проверяется без реальных 5 минут (интервал — параметр модели)
- [x] прогнать тесты — зелёные до Task 5

### Task 5: App/UploadModel — модель экрана

**Files:**
- Create: `kolco24/App/UploadModel.swift`
- Modify: `kolco24/App/AppModel.swift` (фабрика `makeUploadModel()`)
- Create: `kolco24Tests/App/UploadModelTests.swift`

- [x] `@Observable @MainActor UploadModel` (импорты только `Observation`/`Foundation`): наблюдает `markStore.uploadCounts(teamId:raceId:)` → `counts: UploadCounts?` и `outcomeUpdates` актора → исходы текущего скоупа (`[UploadTarget: TargetUploadOutcome]`)
- [x] derived: `pendingLabel` для ряда TeamView («N не отправлено» / «Всё отправлено» / «Пока нечего загружать», `total - cloud`), receipt-данные по целям (`uploaded/total`, done-флаг, вторая строка `relativeTimeRu(atWallMs:nowMs:) · label`), правило видимости «Финиш» (`outcome != nil || uploaded > 0`)
- [x] `refresh() async` — force flush: `await uploadAllPending()` (pull-to-refresh держится до конца дрейна); `nowMs` — инжектированное замыкание (тестируемое относительное время)
- [x] rebind-стейл-гард при смене команды (конвенция пер-таб моделей этапа 4: отмена задач наблюдения + сброс состояния)
- [x] `AppModel.makeUploadModel()` — фабрика по текущему `raceId`/`teamId`
- [x] тесты: счётчики из реальной БД (вставка марок с разными флагами), эмиссия исходов из актора доходит до модели, `refresh()` флипает флаги через `FakeTransport`, `pendingLabel`-градации, rebind при смене команды чистит состояние
- [x] прогнать тесты — зелёные до Task 6

### Task 6: UI — UploadView + ряд в TeamView

**Files:**
- Create: `kolco24/UploadView.swift`
- Modify: `kolco24/TeamView.swift`

- [x] Ряд `MiscRowView` «Загрузка данных» в TeamView (иконка `arrow.up.circle.fill` или аналог, sub = `pendingLabel`), тап → `.sheet` с `UploadView` (конвенция шитов TeamView); модель — через `makeUploadModel()`
- [x] `UploadView`: `List`/`ScrollView` + `.refreshable { await model.refresh() }`; секция «Отметки» — receipt-лайны «Интернет» (всегда) и «Финиш» (по правилу видимости): `uploaded/total` в `Font.mono`, done → зелёный глиф (`GreenCheckCircle`/`Color.good`), error/offline → `Color.brandRed`, вторая строка `«{relativeTime} · {ok|нет интернета|сервер недоступен|ошибка}»`; empty state «Пока нечего загружать»
- [x] дизайн-токены/типографика по `DesignTokens`/`SharedComponents` (адаптивная палитра, `DS.hPad`/`DS.cardRadius`), русский UI; `#Preview` с in-memory окружением
- [x] прогнать полный сьют + сборку — зелёные до Task 7

### Task 7: Верификация приёмки

- [x] все требования Overview реализованы: дуал-таргет идемпотентный батч-дренаж marks, tryLock-семантика, триггеры (таймер/смена команды/закрытие оверлея/pull), экран со счётчиками — проверено по коду (`MarkUploadRepository` actor+`inFlight`, `flushScope` Local→Cloud батч 500 GPS-aware, `AppModel` 5-мин цикл + `scenePhaseChanged` + team-change flush, `MarksView.sheet(onDismiss:)` → `flushUploads`, `UploadView.refreshable`+счётчики)
- [x] grep-инварианты: `Core/Upload` — без `UIKit`/`SwiftUI`/`GRDB`/`CoreNFC` (пусто); `App/`-модели — только `Observation`/`Foundation`; `import GRDB` — только под `Data/` (хиты в `Net/URLSessionTransport` и `App/AppEnvironment` — комментарии, не импорты); `Net/` — без GRDB. Нарушений нет
- [x] полный тест-сьют: `** TEST SUCCEEDED **` (id=9D9F760F… — name-based назначение неоднозначно из-за двух клонов iPhone 16)
- [x] сборка: `** BUILD SUCCEEDED **`

### Task 8: [Final] Документация

- [ ] секция «Upload layer (этап 6)» в `CLAUDE.md` (конвенция пер-этапных секций: что где живёт, ключевые решения/ловушки)
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Живая проверка на устройстве** (бэкенд `/marks/` ещё не поднят — ожидания соответствующие):
- скан реального чипа → взятие в БД → на экране «Загрузка данных» строка «Отметки 0/1», исход «ошибка» (404 от облака) и «сервер недоступен» (LAN-таймаут) — это спроектированный self-heal;
- когда бэкенд поднимут: тот же билд без изменений должен дослать pending-строки (проверить `accepted` и флип счётчиков в `1/1`);
- pull-to-refresh на экране инициирует немедленную попытку (видно по смене relative-time у исхода).

**Решения, отложенные на будущие этапы:**
- этап 7: фото-кадры — `frameDrainLoop` (metadata-first, poison-frame 400/413), `combineOutcome` уже готов;
- этап 8: track-дрейн поверх `drainUploadLoop` + live-upload раз в ~10 мин из записи трека;
- этап 9: LAN-lease; счётчик «Финиш»-лайна станет осмысленным на гонке;
- этап 10: judge_scans-дрейн (60-с таймер) — эндпоинт на сервере тоже не реализован;
- BGTaskScheduler для фоновой досылки — опционально, вне мастер-плана MVP.
