# Этап 8 портирования: GPS-трек

Детализация этапа 8 из [android-port.md](android-port.md). Этапы 0–7 выполнены: чистая логика, GRDB-слой, сеть/sync, `@Observable`-модели, NFC-скан, выгрузка взятий и фото-отметка готовы и покрыты тестами. Этап 8 добавляет запись GPS-трека команды: фоновая запись фиксов в БД сегментами, live-загрузка раз в ~10 мин, дрейн на обе цели, TrackCard в «Команде», GPX-экспорт через share sheet.

## Overview

Карточка «GPS-трек» на вкладке «Команда»: «Начать запись» → фоновая запись фиксов (переживает лок экрана и сворачивание), «Остановить» → lossless-стоп; накопленные точки дренируются батчами по 500 на обе цели (cloud «Интернет» + LAN «Финиш») идемпотентно по клиентскому UUID; live-загрузка пиггибекается на GPS-пробуждения не чаще раза в 10 мин и заодно дошлёт отметки. Записанный трек: метрики (точки/сегменты/время) + «Поделиться GPX» (GPX 1.1, `<trkseg>` на сессию записи).

**Ключевые решения брейншторма (адаптация под платформу, не 1в1 из Kotlin):**
- **Фоновая запись — `CLLocationUpdate.liveUpdates(.fitness)` + `CLBackgroundActivitySession`** (iOS 17+, таргет 18): достаточно уже выданного When-In-Use (этап 5), системный синий индикатор — родной аналог нотификации foreground-сервиса. Никаких Always-запросов, Live Activity и уведомлений. `UIBackgroundModes = location` в оба билд-конфига. Force-quit убивает запись — задокументированный факт (аналог `START_NOT_STICKY`: Android при убийстве сервиса тоже не возобновляет).
- **Только Precise в этом этапе**: `TrackProfile`/`TrackProfilePreference`/Economy/тумблер — этап 9 (экран настроек). Но даунсемплинг нужен уже сейчас: CoreLocation отдаёт ~1 Гц (Android-движок сам держал интервал 15 с) — новая чистая функция `shouldKeepFix` с константой `TRACK_SAMPLE_INTERVAL_MS = 15_000` выравнивает плотность данных с Android.
- **Слой движков умирает**: `LocationEngineFactory`/`chooseEngineType`/`FusedLocationEngine`/`LegacyLocationEngine` (+ `LocationEngineFactoryTest`) не портируются — на iOS один движок. Остаётся seam `TrackEngine` (протокол) для тестируемости `TrackRecorder`.
- **`flush()` не нужен**: CoreLocation отдаёт фиксы сразу (нет maxDelay-буфера, как у Fused) — lossless-стоп упрощается до «отменить цикл, дописать пришедшее»; `FLUSH_TIMEOUT_MS = 4_000` из Kotlin не переносится.
- **GPX-шаринг — SwiftUI `ShareLink`** (не FileProvider): файл во временной директории, share sheet системный.
- **«Очистить трек» в UI не входит** — это экран настроек этапа 9 (`TrackStore.deleteForTeam` уже есть; lossless-guard «не удалять во время записи» добавится на месте вызова в этапе 9).

**Серверный эндпоинт `/app/race/<id>/track/` уже поднят** (в отличие от `/marks/`/фото-кадров на момент этапов 6–7) — живая проверка на устройстве может увидеть реальные 200/`accepted` и флип счётчиков «Интернет». Hard gate этапа остаётся зелёный локальный сьют + сборка; self-heal-механика (транзиентные коды оставляют флаги `0`) — та же, что у отметок.

## Context (from discovery)

**Уже готово и переиспользуется (не переписывать):**
- `Core/Track/Segments.swift` (этап 1) — `nextSegmentId(current:wasTearingDown:mint:)`, `shouldLiveUpload(nowElapsed:lastUploadElapsed:minIntervalMs:)`, `LIVE_UPLOAD_MIN_INTERVAL_MS = 600_000` — вся сегментная/троттлинг-логика с тестами (`SegmentIdTest`/`LiveUploadThrottleTest` зеркалированы).
- `Core/Track/CurrentLocation.swift` (этап 5) — `RawFix` (lat/lon/accuracy/altitude/verticalAccuracyMeters/gpsTimeMs/elapsedRealtimeNanos), `sanitizeFix`, `isFixFresh`.
- `Model/TrackPoint.swift` + `Data/Records/TrackPoint+GRDB.swift` + **полный** `Data/Stores/TrackStore.swift` (этап 2): `observeForTeam`/`countForTeam`/`uploadCounts` (observation), `insertAll` (INSERT OR IGNORE — идемпотентно по UUID), `deleteForTeam`, `unuploadedLocal/Cloud(raceId:teamId:limit:)`, `markUploadedLocal/Cloud(ids:)`, `pendingUploadScopes()`; reboot-safe `ORDER BY COALESCE(trustedMs, wallMs), COALESCE(bootCount, -1), elapsedRealtimeAt, id` уже в SQL.
- `Data/Repositories/MarkUploadRepository.swift` (этап 6) — generic `drainUploadLoop<Row>(fetch:id:upload:mark:)`, `PostResult.mapSuccess`, `uploadResultKind`, `uploadBatch = 500`, идиома actor + `inFlight` + `outcomeUpdates`-стрим (`bufferingNewest(1)`).
- `Core/Upload/UploadModels.swift` — `UploadTarget`/`UploadResultKind`/`TargetUploadOutcome` (для трека `combineOutcome` не нужен — фрейм-цикла нет).
- `Core/Util/PluralRu` — движок склонений + `relativeTimeRu` (этап 6); `Location/CoreLocationProvider.swift` — правила маппинга `CLLocation → RawFix` (`horizontalAccuracy < 0 → Float.greatestFiniteMagnitude`, altitude только при `verticalAccuracy > 0`, монотонный штамп из `mach_continuous_time()` минус возраст фикса) — те же правила в новом движке.
- Триггеры `AppModel` этапа 6: 5-мин foreground-луп + team-change flush — расширяются на трек.
- Паттерны: `@Observable @MainActor`-редьюсер с инжектированными замыканиями (`ScanModel`/`PhotoModel`), unstructured `Task` с захватом сторов (§6 этапа 5), rebind-стейл-гард пер-таб моделей, `FakeTransport`-тесты.

**Kotlin-источники** (в `/Users/alff0x1f/src/kolco24_app_v2`, пакет `app/src/main/java/ru/kolco24/kolco24/`):
- `data/track/TrackModels.kt` — читающая часть (L24–72): `DEFAULT_MAX_ACCURACY_METERS = 50f`, `filterPoints` (**только на чтении** — в БД пишется всё сырьё), `trackPointTimeMs = trustedMs ?: wallMs`, reboot-safe компаратор `(timeMs, bootCount ?: -1, elapsedRealtimeAt, id)`, `sortedTrackPoints`; маппер `toTrackPoint` (L109–132): `elapsedRealtimeAt = elapsedRealtimeNanos / 1_000_000`. Upload-часть L79–98 уже портирована (этап 6).
- `data/track/TrackRepository.kt` — `insertAll` (L70–88): снимок `wallNow`/`elapsedNow`/`bootAt` **один на батч**, `trustedMs = trustedClock.trustedAt(elapsedAt, bootAt)`, back-projection `wallMs = wallNow + (elapsedAt − elapsedNow)`; `uploadPending`/`uploadAllPending`/`flushScope` (Local затем Cloud независимо); `uploadLoop` (L189–206) — семантика уже в generic `drainUploadLoop`; `UPLOAD_BATCH = 500`; `deleteForTeam` с guard (этап 9).
- `TrackRecordingService.kt` — поведение старта/стопа (onStartCommand L119–214, startEngine L222–257, teardown L280–336): TOCTOU-проверка разрешения перед стартом, идемпотентный повторный старт (`nextSegmentId`), live-upload на батче (`shouldLiveUpload` → track + marks `uploadPending`), full teardown (`segmentId = nil`, `lastLiveUploadElapsed = nil`, opportunistic upload). Нотификация/канал/wakelock/flush-таймаут — не портируются.
- `data/track/GpxExport.kt` — GPX 1.1: header `creator="Kolco24"` + xmlns topografix, один `<trkseg>` на **последовательный ран** `segmentId`, `<trkpt lat lon>`, `<ele>` только при altitude, `<time>` ISO-8601 UTC `yyyy-MM-dd'T'HH:mm:ss'Z'` от `trustedMs ?: wallMs`, координаты `%.6f` **с точкой** (Locale.US), `xmlEscape` (`& < > " '`), `gpxFileName(teamLabel, dateIso)` = `kolco24-<safe>-<dateIso>.gpx` (санитизация `[^A-Za-z0-9_-]` → `_`, пустое → `"track"`). Caller pre-filters/pre-sorts.
- `data/track/PointsPlural.kt` — **уже портирован целиком в этапе 6**: `pointsWord`/`pointsLabel`/`segmentsWord`/`relativeTimeRu` живут в `Core/Util/PluralRu.swift` (L28–40), 12 кейсов `PointsPluralTest.kt` — в `kolco24Tests/Core/PluralRuTests.swift`. Не переносить заново.
- `data/api/dto/TrackDtos.kt` + `ApiClient.uploadTrack` (L203–212) — `POST /app/race/<raceId>/track/` (trailing slash); `TrackUploadRequest { team_id, points }` — **без `source_install_id`** (UPLOAD.md его упоминает, но текущий Kotlin-клиент не шлёт — зеркалим клиент, расхождение фиксируем); `TrackPointDto`: `id, segment_id, lat, lon, accuracy, altitude, vertical_accuracy, gps_time_ms, trusted_ms, elapsed_at, boot_count`; локальные `wallMs`/`raceId`/`teamId`/флаги на провод не идут; `TrackUploadResponse { accepted: [String] }`.
- `ui/track/TrackCard.kt` — состояния/строки карточки (см. Task 8).
- **Android-тесты для зеркалирования:** `TrackPointMappingTest.kt` (11), `GpxExportTest.kt` (8), `PointsPluralTest.kt` (12), `TrackUploadTest.kt` (14), `TrackRepositoryTest.kt` (22 — расщепляются на recorder- и upload-части), `TrackProfileTest`/`TrackProfilePreferenceTest` (этап 9), `LocationEngineFactoryTest` (не портируется — мёртвый слой).

## Development Approach

- **testing approach**: порт-конвенция этапов 2–7 — Kotlin-тесты переносятся вместе с модулем в той же задаче (имена кейсов 1:1, header «Зеркало …»); для `TrackRecorder`, `TrackSampling` и UI зеркала нет — тесты свежие (regular: код → тесты в той же задаче) поверх реальных сторов на `AppDatabase.makeInMemory()` + `FakeTrackEngine`/`FakeTransport`;
- complete each task fully before moving to the next;
- make small, focused changes (коммит на задачу);
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task;
- **CRITICAL: all tests must pass before starting next task**;
- **CRITICAL: update this plan file when scope changes during implementation**.

## Testing Strategy

- **unit tests**: Swift Testing. `kolco24Tests/Core/TrackPointsTests`, `TrackPointMapperTests`, `TrackSamplingTests`, `GpxExportTests`; `kolco24Tests/Net/TrackUploadTests` (`FakeTransport`); `kolco24Tests/Data/Repositories/TrackUploadRepositoryTests` (in-memory `TrackStore` + `FakeTransport`); `kolco24Tests/App/TrackRecorderTests` (`@MainActor`, `FakeTrackEngine` со скриптованным стримом + in-memory БД + контролируемое время); дополнения `TeamModelTests`/`UploadModelTests`. (`PointsPlural`-кейсы уже в `PluralRuTests` с этапа 6.)
- **e2e**: автоматизированных нет; фоновый GPS не работает в симуляторе — запись проверяется на устройстве (Post-Completion); эндпоинт `/track/` поднят — сквозная проверка выгрузки на устройстве реальна (200/`accepted`).
- Прогон: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'` (нужен `Config/Secrets.xcconfig`; при флаки-имени — `id=<UDID>` из `xcrun simctl list devices available`).

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview

Поток данных: TrackCard «Начать запись» → `AppModel`/`TrackRecorder.start(raceId:teamId:)` (проверка геодоступа → тост при отказе) → минт `segmentId` (готовый `nextSegmentId`) → движок `CoreLocationTrackEngine` (liveUpdates + `CLBackgroundActivitySession`) → `for await fix`: чистый `shouldKeepFix` (15 с) → `makeTrackPoints` (back-projection времени, trusted через `TrustedClock`) → `trackStore.insertAll` в unstructured `Task` (§6) → на сохранённом фиксе `shouldLiveUpload` (10 мин) → fire-and-forget `trackUploadRepository.uploadPending` + `markUploadRepository.uploadPending` (пиггибек) → «Остановить» → отмена цикла + opportunistic upload → дрейн `TrackUploadRepository.flushScope` (Local → Cloud, `drainUploadLoop`, батч 500, партиал-accepted, анти-луп) → исходы в стрим → `UploadModel`/`UploadView` (секция «Трек») → TrackCard idle: метрики из `sortedTrackPoints(filterPoints(…))` + «Поделиться GPX» (`buildGpx` → temp-файл → `ShareLink`).

Ключевые решения:
- **Чистое ядро в `Core/Track/`** (Foundation-only, зеркальные тесты): читающие хелперы (`filterPoints`/компаратор/`sortedTrackPoints`), маппер батча (`makeTrackPoints` — время/uuid инжектами, идиома `makeKpTakeMark`), даунсемплинг (`shouldKeepFix`), `GpxExport`; track-словарь в `PluralRu`.
- **Seam `TrackEngine`** (протокол в Core: `fixes() -> AsyncStream<RawFix>`, `stop()`) + прод-адаптер `Location/CoreLocationTrackEngine` (единственный новый `import CoreLocation`-файл; device-only, юнитами не кроется — прецедент `NfcChipScanner`).
- **`App/TrackRecorder`** (`@Observable @MainActor`, только `Observation`/`Foundation`) — один экземпляр в графе (переживает уходы с таба), редьюсер записи: старт/стоп/идемпотентность/live-upload-троттлинг; тестируем через `FakeTrackEngine` + инжектированное время.
- **`Data/Repositories/TrackUploadRepository`** (actor, `import GRDB`) — клон структуры `MarkUploadRepository` поверх готовых `TrackStore` + `drainUploadLoop`; маркировка `markUploadedLocal/Cloud(ids:)` **без version-guard** — точки иммутабельны (нет аналога `addMember`/`attachLocation`); фрейм-цикла и `combineOutcome` нет.
- **TrackCard — в `TeamModel`** (прецедент bind-flow: отдельной модели не заводим): track-производные через подписку `trackStore.observeForTeam` + rebind-стейл-гард; состояние записи из `TrackRecorder` через `AppModel`.

## Technical Details

- **Маппинг батча** (`makeTrackPoints`): снимок `wallNow`/`elapsedNow`/`bootCount` один на батч; per fix: `elapsedAt = elapsedRealtimeNanos / 1_000_000`, `trustedMs = trustedMsFor(elapsedAt)` (**синхронное** инжектированное замыкание), `wallMs = wallNow + (elapsedAt − elapsedNow)` (back-projection), `id = idFactory()`, `uploadedLocal/Cloud = false`. Чистая функция — UUID и время параметрами. **Прод-вайринг trusted-времени**: `TrustedClock.trustedAt(elapsedAt:bootAt:)` — actor-isolated `async` (см. `Core/Time/TrustedClock.swift:172`), в sync-замыкание не заворачивается (и семафорный мост на main запрещён — прецедент `syncSample` санкционирован только для NFC-очереди); `TrackRecorder` **заранее `await`-ит** значение в своём async-цикле (`let trusted = await trustedClock.trustedAt(elapsedAt: elapsedAt, bootAt: bootCount)`) и передаёт готовое: `trustedMsFor: { _ in trusted }`; `bootAt` — из батч-снимка `bootCount`.
- **Даунсемплинг**: `shouldKeepFix(nowElapsed:lastKeptElapsed:intervalMs:) -> Bool` — nullable-сентинел как `shouldLiveUpload` (первый фикс всегда сохраняется, reboot/overflow-safe); `TRACK_SAMPLE_INTERVAL_MS: Int64 = 15_000` (Precise; Economy-профиль — этап 9). `nowElapsed` — от `fix.elapsedRealtimeNanos / 1_000_000` (монотонно).
- **Движок**: `CLLocationUpdate.liveUpdates(.fitness)` в `Task` на неизолированном контексте; `CLBackgroundActivitySession` создаётся на старте записи и инвалидируется на стопе (держит фоновые обновления при When-In-Use); `update.location == nil` и `update.isStationary` — пропуск; маппинг `CLLocation → RawFix` теми же правилами, что `CoreLocationProvider` (включая синтез монотонного штампа из `mach_continuous_time()` минус возраст фикса → `elapsedRealtimeNanos`).
- **`TrackRecorder.start`**: guard «уже пишем» — повторный старт не меняет сегмент (`nextSegmentId(current:wasTearingDown:mint:)`); проверка геодоступа (инжект `hasLocationAccess: () -> Bool` от Location-адаптера; отказ → `toastMessage` через `AppModel`, запись не стартует — TOCTOU-паттерн сервиса). `stop()`: отмена цикла, `engine.stop()`, `session.invalidate()`, `segmentId = nil`, `lastLiveUploadElapsed = nil`, `.idle`, opportunistic `uploadPending` track + marks (fire-and-forget, захват репозиториев). Смена/сброс команды → `stop()` — хук в существующем `selectedTeamStore`-observation `AppModel`, **только при подлинной смене**: стоп лишь когда рекордер в `.recording(teamId:)` и новый `selection.teamId` отличается (или выбор сброшен) — observation срабатывает и на стартовой эмиссии, и на повторной эмиссии той же команды после resync, безусловный `stop()` молча убил бы живую запись (зеркало guard'а `MainActivity.kt` L893–899).
- **DB-записи** — unstructured `Task` с захватом **сторов** (не `self`): закрытие UI/уход с таба не рвёт вставку; вставка идемпотентна (INSERT OR IGNORE по UUID).
- **Live-upload**: на каждом **сохранённом** фиксе `shouldLiveUpload(nowElapsed:lastLiveUploadElapsed:LIVE_UPLOAD_MIN_INTERVAL_MS)`; true → штамп + fire-and-forget `trackUploadRepository.uploadPending(raceId:teamId:)` и `markUploadRepository.uploadPending(raceId:teamId:)` (пиггибек на GPS-пробуждение — конвенция Android, без лишних таймеров).
- **DTO** (`Net/Dto/TrackUpload.swift`): правило nullable-кодирования этапа 6 — no-default nullable-поля (`altitude`, `vertical_accuracy`, `trusted_ms`, `boot_count`) пишутся **явным JSON `null`** (ручной `encode(to:)`); `TrackUploadRequest` — **без `source_install_id`** (зеркало текущего Kotlin-клиента, не UPLOAD.md; расхождение — комментарием в DTO).
- **`ApiClient.uploadTrack(raceId:teamId:points:) async -> PostResult<TrackUploadResponse>`** — generic `post` (тело сериализуется один раз, подпись по тем же байтам, **never retries**), путь `/app/race/<raceId>/track/` (trailing slash — как `/marks/`).
- **`TrackUploadRepository`** (actor): `inFlight`-tryLock, `uploadPending(raceId:teamId:)`, `uploadAllPending()` по `trackStore.pendingUploadScopes()`, `flushScope` = Local → Cloud, каждый через `drainUploadLoop` (fetch = `unuploadedLocal/Cloud(limit: 500)`, mark = `markUploadedLocal/Cloud(ids:)` — без version-guard); `outcomes: [TrackScope: [UploadTarget: TargetUploadOutcome]]` + `outcomeUpdates` (`bufferingNewest(1)`), `wallNow` инжектом.
- **Триггеры**: 5-мин foreground-луп и team-change flush в `AppModel` дополняются `trackUploadRepository.uploadAllPending()`.
- **TrackCard-производные** (`TeamModel`): `trackUsable = sortedTrackPoints(filterPoints(points))`, `pointCount`, `segmentCount` (distinct `segmentId` по `trackUsable`), «Время» = `HH:mm` первой–последней точки (`trackPointTimeMs`); `degradedAccuracy` = `accuracyAuthorization == .reducedAccuracy` (инжект-замыкание от Location-адаптера — iOS-аналог андроидного «нет GPS-провайдера»).
- **GPX-шаринг**: офф-мейн `buildGpx(trackUsable, teamName)` → запись в `FileManager.temporaryDirectory/tracks/<gpxFileName>` → `ShareLink`/share sheet; имя файла от `gpxFileName(teamLabel:dateIso:)` (`dateIso` — `RaceDates.todayIso`).
- **project.pbxproj**: `INFOPLIST_KEY_UIBackgroundModes = location` в оба build config (конвенция ключей этапов 5/7).

## What Goes Where

- **Implementation Steps**: код, тесты, документация — всё проверяемо сборкой/сьютом в симуляторе.
- **Post-Completion**: фоновая запись/живой GPS — только на устройстве; живая выгрузка — когда поднимут бэкенд.

## Implementation Steps

### Task 1: Core — TrackPoints (чтение)

**Files:**
- Create: `kolco24/Core/Track/TrackPoints.swift`
- Create: `kolco24Tests/Core/TrackPointsTests.swift`

- [x] `DEFAULT_MAX_ACCURACY_METERS: Float = 50`, `filterPoints(_:maxAccuracyMeters:)` (только чтение — БД хранит всё), `trackPointTimeMs(_:) = trustedMs ?? wallMs`, reboot-safe сортировка `(timeMs, bootCount ?? -1, elapsedRealtimeAt, id)`, `sortedTrackPoints(_:)` — зеркало `TrackModels.kt` L24–72 (работают по `TrackPoint`; `TrackPointLike`-протокол не нужен, тип один)
- [x] track-словарь **не добавлять**: `pointsWord`/`pointsLabel`/`segmentsWord`/`relativeTimeRu` уже в `Core/Util/PluralRu.swift` с этапа 6 (повторное добавление — duplicate-declaration), их тесты — в `PluralRuTests`
- [x] тесты `TrackPointsTests` (зеркало фильтр/сорт-кейсов `TrackPointMappingTest.kt`): `filterPoints_keepsFixesMeetingThreshold_dropsCoarser`, `filterPoints_customThreshold`, `filterPoints_emptyList`, `sortedTrackPoints_ordersByTrustedOrWallBeforeElapsedAcrossReboot`
- [x] прогнать тесты — зелёные до Task 2

### Task 2: Core — маппер батча и даунсемплинг

**Files:**
- Create: `kolco24/Core/Track/TrackPointMapper.swift`
- Create: `kolco24/Core/Track/TrackSampling.swift`
- Create: `kolco24Tests/Core/TrackPointMapperTests.swift`
- Create: `kolco24Tests/Core/TrackSamplingTests.swift`

- [x] `makeTrackPoints(fixes:raceId:teamId:segmentId:wallNow:elapsedNow:bootCount:trustedMsFor:idFactory:) -> [TrackPoint]` — зеркало `TrackRepository.insertAll` L70–88 + `toTrackPoint` L109–132: снимок времени один на батч, `elapsedAt = nanos / 1_000_000`, back-projection `wallMs = wallNow + (elapsedAt − elapsedNow)`, `trustedMs = trustedMsFor(elapsedAt)`, флаги `false`; пустой вход → `[]`
- [x] `shouldKeepFix(nowElapsed:lastKeptElapsed:intervalMs:) -> Bool` (nullable-сентинел, форма `shouldLiveUpload`) + `TRACK_SAMPLE_INTERVAL_MS: Int64 = 15_000` — новая (не порт), doc-комментарий «CoreLocation ~1 Гц → выравнивание с Android-интервалом»
- [x] тесты `TrackPointMapperTests` (зеркало `TrackPointMappingTest.kt`): `elapsedRealtimeAt_isNanosDividedByMillion`, `fieldsArePassedThrough`, `segmentId_comesFromInjectedValue`, `altitudeFields_nullWhenFixHasNoVerticalComponent`, `trustedMs_comesFromInjectedValue`, `trustedMs_nullWhenNoClockSync`, `idFactoryIsInvokedPerMapping` + батч-кейсы `insertAll_*` из `TrackRepositoryTest.kt` (back-projection у каждого фикса, пустой батч, distinct segmentId у двух сессий)
- [x] тесты `TrackSamplingTests` (свежие, матрица как у `LiveUploadThrottleTest`): первый фикс всегда true, дельта ниже/на границе/выше интервала, «сразу после ребута» (маленький nowElapsed, lastKept == nil → true)
- [x] прогнать тесты — зелёные до Task 3

### Task 3: Core — GpxExport

**Files:**
- Create: `kolco24/Core/Track/GpxExport.swift`
- Create: `kolco24Tests/Core/GpxExportTests.swift`

- [x] `buildGpx(points:trackName:) -> String` — зеркало `GpxExport.kt` 1:1: header GPX 1.1 `creator="Kolco24"` + xmlns topografix, `<name>` с XML-эскейпом, один `<trkseg>` на последовательный ран `segmentId`, `<trkpt lat="…" lon="…">` в `%.6f` с точкой (Locale-независимо), `<ele>` только при `altitude != nil`, `<time>` ISO-8601 UTC `yyyy-MM-dd'T'HH:mm:ss'Z'` от `trackPointTimeMs`; caller pre-filters/pre-sorts
- [x] `xmlEscape(_:)` (`& < > " '`) и `gpxFileName(teamLabel:dateIso:)` = `kolco24-<safe>-<dateIso>.gpx` (санитизация `[^A-Za-z0-9_-]` → `_`, пустое → `"track"`)
- [x] тесты (зеркало `GpxExportTest.kt`, 8 кейсов): `emptyList_producesValidEmptyTrack`, `distinctSegmentIds_produceSeparateTrksegs`, `callerSideRebootSafeSorting_preventsAlternatingOnePointSegments`, `altitude_omittedWhenNull_presentWhenSet`, `time_usesTrustedThenWall_inUtcIso`, `coordinates_useDotDecimalSeparator`, `trackName_isXmlEscaped`, `fileName_sanitizesAndStamps`
- [x] прогнать тесты — зелёные до Task 4

### Task 4: Seam TrackEngine + Location/CoreLocationTrackEngine + фоновый режим

**Files:**
- Create: `kolco24/Core/Track/TrackEngine.swift`
- Create: `kolco24/Location/CoreLocationTrackEngine.swift`
- Modify: `kolco24/Info.plist` (`UIBackgroundModes` = `[location]` массив) ⚠️ **не** через `INFOPLIST_KEY_` — см. ниже
- Modify: `kolco24Tests/InfoPlistTests.swift` (смоук-лок `UIBackgroundModes`)

- [x] `protocol TrackEngine: AnyObject { func fixes() -> AsyncStream<RawFix>; func stop() }` в Core (+ doc: без `flush` — CoreLocation отдаёт сразу, lossless-стоп = отмена цикла; конец стрима = движок остановлен)
- [x] `CoreLocationTrackEngine` (`import CoreLocation`): `CLBackgroundActivitySession` на время работы + `Task` над `CLLocationUpdate.liveUpdates(.fitness)`; пропуск `location == nil`/`isStationary`; маппинг `CLLocation → RawFix` правилами `CoreLocationProvider` (accuracy < 0 → `.greatestFiniteMagnitude`, altitude при `verticalAccuracy > 0`, монотонный штамп из `mach_continuous_time()` минус возраст); `stop()` идемпотентен (отмена Task + invalidate сессии); хелперы `hasLocationAccess()`/`isReducedAccuracy()` для инжектов — оба читают `authorizationStatus`/`accuracyAuthorization` с **удерживаемого** `CLLocationManager` (инстанс живёт в адаптере, не одноразовый в замыкании)
- [x] ⚠️ **отклонение от плана**: `INFOPLIST_KEY_UIBackgroundModes` в pbxproj **не работает** — Xcode 26 не поддерживает этот `INFOPLIST_KEY_` для массива-ключа (проверено: ключ молча не попадает в слитый plist, в отличие от строковых `INFOPLIST_KEY_NSCamera…`/`NFCReader…`). Ключ добавлен как настоящий `<array><string>location</string></array>` прямо в `kolco24/Info.plist` (штатный merge-путь проекта, `GENERATE_INFOPLIST_FILE = YES`); залочен новым смоук-тестом `InfoPlistTests.backgroundLocationModeIsDeclared` (проверил: `UIBackgroundModes` реально попадает в слитый `kolco24.app/Info.plist`)
- [x] сборка проходит; юнит-тестов на адаптер нет (device-only — прецедент `NfcChipScanner`/`PhotoCameraController`); поведенческая логика кроется `TrackRecorderTests` (Task 6) через seam
- [x] прогнать полный сьют + сборку — зелёные до Task 5

### Task 5: Net + Data — DTO, uploadTrack, TrackUploadRepository, триггеры

**Files:**
- Create: `kolco24/Net/Dto/TrackUpload.swift`
- Modify: `kolco24/Net/ApiClient.swift`
- Create: `kolco24/Data/Repositories/TrackUploadRepository.swift`
- Modify: `kolco24/App/AppEnvironment.swift` (репозиторий в граф)
- Modify: `kolco24/App/AppModel.swift` (5-мин луп + team-change flush зовут track)
- Create: `kolco24Tests/Net/TrackUploadTests.swift`
- Create: `kolco24Tests/Data/Repositories/TrackUploadRepositoryTests.swift`

- [x] `TrackUploadRequest { team_id, points }` (**без** `source_install_id` — зеркало Kotlin-клиента, расхождение с UPLOAD.md комментарием), `TrackPointDto` (11 полей, snake_case `CodingKeys`: `segment_id`, `vertical_accuracy`, `gps_time_ms`, `trusted_ms`, `elapsed_at`, `boot_count`; ручной `encode(to:)` — nullable явным `null`; `init(from point: TrackPoint)` дропает `wallMs`/`raceId`/`teamId`/флаги), `TrackUploadResponse { accepted }` — `kolco24/Net/Dto/TrackUpload.swift`
- [x] `ApiClient.uploadTrack(raceId:teamId:points:) async -> PostResult<TrackUploadResponse>` — generic `post` на `/app/race/<raceId>/track/` (trailing slash, never retries)
- [x] `TrackUploadRepository` (actor): `inFlight`-tryLock, `uploadPending`/`uploadAllPending` по `trackStore.pendingUploadScopes()`, `flushScope` Local → Cloud через generic `drainUploadLoop` (fetch `unuploadedLocal/Cloud(limit: uploadBatch)`, mark `markUploadedLocal/Cloud(ids:)`), `outcomes` + `outcomeUpdates` (`bufferingNewest(1)`), `wallNow` инжектом — структурный клон `MarkUploadRepository` без фрейм-цикла/version-guard (переиспользует свободные `drainUploadLoop`/`uploadResultKind`; свой file-private `mapSuccessTrack`)
- [x] `AppEnvironment`: `trackStore` + `trackUploadRepository` в граф (прод и `inMemory`); `AppModel`: 5-мин foreground-луп и team-change flush дополнены `trackUploadRepository.uploadAllPending()`
- [x] тесты `TrackUploadTests` (зеркало `TrackUploadTest.kt` через `FakeTransport`): 200 → accepted + путь/метод/тело (JSON: `segment_id` присутствует, nullable → явный `null`, `wall_ms`/локальные поля отсутствуют, `source_install_id` отсутствует), 403/401/400/429 → соответствующие `PostResult` (403 — ровно один запрос), URLError → `.offline`, пустой батч → пустой `points`
- [x] тесты `TrackUploadRepositoryTests` (зеркало upload-части `TrackRepositoryTest.kt`, in-memory `TrackStore`): `uploadPending_marksPerTargetIndependently`, `uploadPending_doesNotRetryAlreadyUploaded`, `uploadPending_partialAccepted_marksOnlyAccepted_thenBreaks`, `uploadPending_emptyAccepted_breaksWithoutLooping`, `uploadAllPending_walksEveryScope`, `upload_reentrant_isNoOp`, исходы: offline оба таргета / успешный дрейн → ok / forbidden → error / no-forward-progress → error not ok / нет pending → исход не репортится (+ батчинг >500, db-ошибка → .error)
- [x] прогнать тесты — зелёные до Task 6 (полный сьют: 893 теста в 73 сьютах, `** TEST SUCCEEDED **`)

### Task 6: App — TrackRecorder

**Files:**
- Create: `kolco24/App/TrackRecorder.swift`
- Modify: `kolco24/App/AppEnvironment.swift` (фабрика движка + `hasLocationAccess`/`isReducedAccuracy` замыкания; `inMemory` — фейки)
- Modify: `kolco24/App/AppModel.swift` (владение рекордером, стоп при смене команды)
- Create: `kolco24Tests/App/TrackRecorderTests.swift`

- [x] `@Observable @MainActor TrackRecorder` (только `Observation`/`Foundation`): `enum TrackState { idle, recording(teamId: Int) }` (порт `TrackState.kt`; `pointCount` для UI — отдельной подпиской `countForTeam`, не в enum-стейте — это сырой live-счётчик, **не** объединять с фильтрованными idle-метриками `TeamModel`), deps: `trackStore`, `trackUploadRepository`, `markUploadRepository`, `trustedClock` (actor), `makeEngine: () -> any TrackEngine`, `hasLocationAccess: () -> Bool`, `wallNow`/`elapsedNow`/`bootCount`/`idFactory` инжектами (идиома `ScanModel` — всё контролируемо в тестах)
- [x] `start(raceId:teamId:)`: TOCTOU-проверка `hasLocationAccess` (отказ → колбэк тоста, не стартуем); идемпотентность через `nextSegmentId` (повторный старт при живой записи — no-op, сегмент тот же); цикл `for await fix in engine.fixes()`: `shouldKeepFix(15 с)` → skip или **`await trustedClock.trustedAt(elapsedAt:bootAt:)` прямо в async-цикле** → `makeTrackPoints([fix], …, trustedMsFor: { _ in trusted })` → `trackStore.insertAll` в unstructured `Task` с захватом стора (§6)
- [x] live-upload: на сохранённом фиксе `shouldLiveUpload(nowElapsed:lastLiveUploadElapsed:LIVE_UPLOAD_MIN_INTERVAL_MS)` → штамп + fire-and-forget `uploadPending` track **и** marks (пиггибек, захват репозиториев)
- [x] `stop()`: `.idle`, сброс сессии, opportunistic fire-and-forget `uploadPending` track + marks; стоп-старт минтит новый сегмент (`stopThenStart_producesTwoDistinctSegments`). ⚠️ **уточнение**: цикл фиксов на стопе **не отменяется** — `engine.stop()` завершает стрим, и цикл сперва дренирует уже пришедшие (буферизованные) фиксы, а лишь потом выходит (lossless-стоп, порт ScanModel-идиомы «finish() даёт дренировать»); состояние даунсемплинга/троттлинга/сегмента вынесено в ссылочный `Session`, захватываемый циклом, — поздний фикс старой сессии после стоп→старт обновляет свой объект, а не счётчики новой (сегментная изоляция)
- [x] `AppModel`: `trackRecorder` в графе (один экземпляр), смена/сброс команды в `selectedTeamStore`-observation зовёт `trackRecorder.stop()` **только при подлинной смене** (рекордер `.recording(teamId:)` и новый `selection.teamId` ≠ пишущемуся, либо выбор сброшен — стартовая/повторная эмиссия той же команды запись не трогает; порт guard'а `MainActivity` L893–899); прод-`makeEngine` = `CoreLocationTrackEngine` (удерживаемый инстанс: и `fixes()`, и чтения `hasLocationAccess`/`isReducedAccuracy`), `inMemory` → `NoTrackEngine`-фейк
- [x] тесты (FakeTrackEngine со скриптованным стримом + in-memory БД + контролируемое время): фиксы маппятся и ложатся в БД с `segmentId`/back-projection/`trustedMs`; даунсемплинг режет фиксы чаще 15 с; идемпотентный повторный `start` не меняет сегмент; stop→start даёт два distinct сегмента; live-upload триггерится по 10-мин троттлингу (роутящий транспорт-спай) и на первом батче; `stop` дописывает пришедшее и шлёт opportunistic upload; смена команды останавливает запись, **повторная эмиссия той же команды — нет**; отказ геодоступа → нет старта + тост
- [x] прогнать тесты — зелёные до Task 7 (полный сьют: 903 теста в 74 сьютах, `** TEST SUCCEEDED **`)

### Task 7: UI — TrackCard в «Команде» + GPX-шаринг

**Files:**
- Modify: `kolco24/App/TeamModel.swift` (track-производные)
- Modify: `kolco24/TeamView.swift` (TrackCardView + вход)
- Modify: `kolco24Tests/App/TeamModelTests.swift`

- [x] `TeamModel`: подписка `trackStore.observeForTeam` (rebind-стейл-гард как у остальных), производные `trackUsable = sortedTrackPoints(filterPoints(points))`, `trackPointCount`, `trackSegmentCount` (distinct `segmentId`), `trackTimeRange` («HH:mm–HH:mm» / «HH:mm» / `nil` от `trackPointTimeMs` первой–последней); `degradedAccuracy` от инжект-замыкания `isReducedAccuracy` (init-параметр, протянут `makeTeamModel` → `env.isReducedAccuracy`). `trackPointCount`/`trackSegmentCount` — по СЫРЫМ точкам (порт `safeTrack.size`), фильтр только у `trackUsable`/времени/GPX
- [x] `TrackCardView` (строки 1:1 `TrackCard.kt`): заголовок «GPS-трек» (`SectionHeader`); recording → пульсирующая точка + «Идёт запись» + `pointsLabel(recorder.pointCount)` (`Font.mono`) + «Остановить» (`brandRed`); idle + 0 точек → «Запишите GPS-трек команды во время гонки.» + CTA «Начать запись» (`kolcoOrange`, disabled без команды); idle + >0 → метрики Точки/Сегменты/Время (`Font.mono`, `capitalizedFirst` слова из `pointsWord`/`segmentsWord`, «Время») + «Начать запись» + вторичная «Поделиться GPX»; хинт «Только примерная геолокация (нет GPS).» при `degradedAccuracy`; дизайн-токены/`DS`-отступы
- [x] действия: старт/стоп через `appModel.trackRecorder`; **вью держит и `model` (TeamModel), и `appModel.trackRecorder`** (оба `@Observable` — SwiftUI трекает `recorder.state`/`recorder.pointCount` напрямую); «Поделиться GPX» — офф-мейн `buildGpx(trackUsable, trackName)` (`Task.detached`) → файл `FileManager.temporaryDirectory/tracks/<gpxFileName(teamLabel:dateIso:)>` (`todayIso`) → `ShareLink`, пере-генерится в `.task(id: trackUsable)`; `teamLabel` = стартовый номер/id, `trackName` = teamname/«Команда N»
- [x] тесты `TeamModelTests` (дополнения, in-memory БД): производные точек/сегментов/времени от вставленных `TrackPoint` (в т.ч. фильтр accuracy > 50 сырьё-vs-usable и reboot-safe порядок по `bootCount`, одиночная точка, диапазон), rebind при смене команды чистит track-стейт, `degradedAccuracy` от замыкания
- [x] прогнать полный сьют + сборку — зелёные до Task 8 (`** TEST SUCCEEDED **`, name-based destination был неоднозначен → прогон по UDID iPhone 16 / OS 18.0)

### Task 8: Upload UI — секция «Трек»

**Files:**
- Modify: `kolco24/App/UploadModel.swift`
- Modify: `kolco24/UploadView.swift`
- Modify: `kolco24Tests/App/UploadModelTests.swift`

- [x] `UploadModel`: подписка `trackStore.uploadCounts` + сид/стрим исходов `TrackUploadRepository.outcomeUpdates` (идиома этапа 6); receipt-строки «Трек» по правилам этапов 6/7 («Интернет» всегда при ненулевых точках, «Финиш» по `outcome != nil || uploaded > 0`, вторая строка «{relativeTimeRu} · {исход}»); `pendingLabel` ряда TeamView учитывает точки (total − cloud по всем видам)
- [x] `UploadView`: секция «Трек» (скрыта при нуле точек — правило секции «Фото»), счётчики `uploaded/total` в `Font.mono`, глифы done/error по токенам; `refresh()` (pull-to-refresh = force-flush) зовёт и `trackUploadRepository.uploadAllPending()`
- [x] тесты: точки pending → секция видна с корректными счётчиками; 0 точек → скрыта; исход offline/error → строка-receipt; `pendingLabel` суммирует отметки+кадры+точки
- [x] прогнать тесты — зелёные до Task 9 (полный сьют: 913 тестов в 74 сьютах, `** TEST SUCCEEDED **`)

### Task 9: Верификация приёмки

- [x] все требования Overview: фоновая запись с даунсемплингом 15 с (`shouldKeepFix`/`TRACK_SAMPLE_INTERVAL_MS=15_000` в `Core/Track/TrackSampling.swift`), сегменты (`nextSegmentId` в `Segments.swift`, зовётся из `TrackRecorder`), идемпотентный старт/стоп, live-upload раз в 10 мин (`shouldLiveUpload` + пиггибек `trackUploadRepository`/`markUploadRepository` в `TrackRecorder.swift`), дрейн на обе цели с self-heal (`TrackUploadRepository.flushScope` Local→Cloud подтверждён), TrackCard со всеми состояниями (`TrackCardView` в `TeamView.swift`: «Начать запись»/«Остановить»/«Поделиться GPX»/`degradedAccuracy`), GPX-шаринг (`buildGpx` + `ShareLink`), секция «Трек» (`UploadModel`/`UploadView`). Все реализованы, гэпов нет
- [x] grep-инварианты (все пусты): `import CoreLocation` только под `Location/`; `Core/`/`Model/`/`App/`-модели (`TrackRecorder`/`TeamModel`/`UploadModel`/`ScanModel`/`PhotoModel`/`AppModel` импортируют только `Foundation`/`Observation`) без `UIKit`/`SwiftUI`/`GRDB`/`CoreNFC`/`CoreLocation`/`AVFoundation`/`ImageIO`; `import GRDB` только под `Data/`; `Net/` без GRDB (единичные совпадения `grep` — только в комментариях, не `import`-строки)
- [x] полный тест-сьют: `** TEST SUCCEEDED **` (913 тестов в 74 сьютах, UDID iPhone 16 / OS 18.0, `-parallel-testing-enabled NO`)
- [x] сборка: `** BUILD SUCCEEDED **` (тест-команда собирает проект — успех сборки подтверждён)

### Task 10: [Final] Документация

- [x] секция «Track layer (этап 8)» в `CLAUDE.md` (что где живёт; ловушки: даунсемплинг vs Android-интервал, back-projection wallMs, отсутствие flush/`FLUSH_TIMEOUT_MS`, `source_install_id`-расхождение с UPLOAD.md, force-quit убивает запись, `UIBackgroundModes`)
- [x] обновить `docs/plans/android-port.md` (этап 8 — done, пометка «профили/очистка → этап 9»)
- [x] move this plan to `docs/plans/completed/`

## Post-Completion

**Живая проверка на устройстве** (фоновый GPS не работает в симуляторе; эндпоинт `/track/` поднят — выгрузку можно проверить вживую):
- старт записи → лок экрана / сворачивание → прогулка 10+ мин → стоп: точки в БД с одним `segmentId`, интервалы ~15 с, синий системный индикатор во время записи;
- стоп → старт: новый сегмент; GPX из двух сегментов открывается во внешнем приложении (две `<trkseg>`, без «телепорт-линии»);
- смена команды во время записи → запись остановлена;
- force-quit во время записи → запись не возобновляется (задокументированное поведение);
- экран «Загрузка данных»: секция «Трек» — при онлайне счётчик «Интернет» доходит до `total/total` (реальные 200/`accepted` с сервера), точки видны на сервере; «Финиш» (LAN) вне гонки остаётся pending — норма;
- live-upload: во время длинной записи раз в ~10 мин уходит выгрузка (точки появляются на сервере ещё до стопа), отметки дошлются заодно;
- повторная выгрузка (pull-to-refresh после полного дрейна) не создаёт дублей на сервере (идемпотентность по клиентскому UUID).

**Решения, отложенные на будущие этапы:**
- этап 9: `TrackProfile` Precise/Economy + `TrackProfilePreference` + тумблер «Экономия батареи», «Очистить трек» (guard «не во время записи»), LAN-lease;
- BGTaskScheduler для фоновой досылки — вне MVP.
