# Этап 5 портирования: NFC-отметка на КП (ядро приложения)

Детализация этапа 5 из [android-port.md](android-port.md). Этапы 0–4 выполнены: чистая логика (`Core/`, `Model/`), GRDB-слой (`Data/`), сеть/sync-репозитории (`Net/`, `Data/Repositories/`) и `@Observable`-модели поверх реальных данных (`App/`) готовы и покрыты тестами.

## Overview

Этап 5 делает приложение полезным на гонке: NFC-скан чипа КП + браслетов → персист взятия в БД, one-shot GPS-фикс на момент взятия (анти-фрод), звук/вибро-фидбек, привязка браслетов к участникам (BindChipSheet).

**Ключевая адаптация под платформу (требование: не 1в1 из Kotlin).** В Android скан-оверлей открывается *самим чипом*: reader mode включён постоянно, тап по чипу в «простое» приложения открывает оверлей и передаёт первый скан внутрь. На iOS постоянного reader mode нет (K24-чипы не NDEF — фоновое чтение недоступно): вход всегда через существующий FAB в `MarksView`. Внутри оверлея — **одна длинная `NFCTagReaderSession`** (решение брейншторма): старт при открытии шита, `restartPolling()` между чтениями, прогресс в `alertMessage` системной шторки, тихий рестарт новой сессии по 60-с системному таймауту/ошибке чтения, пока живо наше 20-секундное окно. 20-с окно (`ScanSession`, промежуток между принятыми сканами) и 60-с лимит iOS (суммарная жизнь одной сессии) — независимые таймеры; рестарт прячет лимит под капот, для участника это короткое мигание шторки без потери состояния.

Вне скоупа (по мастер-плану): загрузка взятий на сервер (этап 6 — hook при закрытии оверлея остаётся no-op), фото-отметка (этап 7), GPS-трек (этап 8), запись/провижининг чипов через `writeRecord` 0xA2 (этап 10 — чистая логика уже покрыта тестами), празднования/skew-баннер (этап 11).

## Context (from discovery)

**Уже готово и переиспользуется (не переписывать):**
- `Core/Scan/ScanSession.swift` — `reduce`/`classifyTag`/`isComplete`/`isWindowExpired`, `SCAN_WINDOW_MS` (зеркала: `ScanSessionTests` 25, `ScanTagDecisionTests` 9).
- `Core/Scan/ScanFeedback.swift` — `feedbackFor` (`ScanFeedbackTests`).
- `Core/Nfc/ChipRecord.swift` — `protocol NfcTransport { transceive }`, чистый `readRecord` (FAST_READ 0x3A → фоллбек 2×READ 0x30), `parseChipRecord`, `chipCodeHex` (`ChipRecordTests` 41 — read/write-часть **уже зеркалирована** через `FakeTransport`).
- `Core/Nfc/NfcUid.swift` — `normalizeNfcUid` (`NfcUidTests`).
- `Core/Team/BindDecision.swift` — `decideBind`/`BindOutcome`/`SlotKey` (`BindChipDecisionTests` 7).
- `Core/Time/TrustedClock.swift` — актор с `sample() -> TimeSample(wallMs, elapsedMs, trustedMs, bootCount)`.
- `Data/Stores/MarkStore.swift` — `upsert`, транзакционный `addMember` (идемпотентный read-modify-write, пересчёт `complete`, сброс `uploaded*`), `attachLocation` (колоночный UPDATE 7 `loc*`-полей — гонка с `addMember` безопасна by design).
- `Data/Stores/MemberChipBindingStore.swift` — `findByUid`, атомарный `reassign` (deleteByUid→upsert в одной транзакции), `deleteSlot`, `observeForTeam`.
- `Data/Stores/MemberTagStore.swift` — `observeForRace`, `findByUid(raceId:nfcUid:)`; `MemberTagsRepository.hasBeenSynced`/`refreshMemberTags`.
- `LegendRepository.unlock(raceId:code:) -> UnlockOutcome` — оффлайн-крипто + reveal КП в БД.
- Entitlement `com.apple.developer.nfc.readersession.formats = [TAG]` (`kolco24.entitlements`) и `INFOPLIST_KEY_NFCReaderUsageDescription` — уже настроены (NFC-спайк работал на устройстве).
- Спайк `kolco24/NFCReader.swift` (дублирует парсинг K24 и FAST_READ-фоллбек) — **удаляется**, заменяется слоем `Nfc/`.
- `MarksView.FloatingCTAView` уже открывает `ScanSheet` (`showScan`); «Привязать» в `TeamView` — видимая заглушка-алерт (`showBindStub`).
- `AppEnvironment.makeShared()` сейчас **теряет** `pair.clock` из `ApiClients.makeDefaultPair()` — этап 5 добавляет `trustedClock` в граф.

**Kotlin-источники** (в `/Users/alff0x1f/src/kolco24_app_v2`, пакет `app/src/main/java/ru/kolco24/kolco24/`):
- `MainActivity.kt` — `onTagDiscovered` (~361–414: семпл часов **до** чтения чипа, приоритетная лестница хуков), `ScanTakeState` (~475–483), `onScanTag`-редьюсер (~1329–1468 — самая сложная часть порта), GPS-attach (~1409–1411), permission-запрос (~994–1024), `closeScanOverlay` (~1311–1319).
- `data/MarkRepository.kt` — `startKpTake` (127–167: UUID, `distinctBy{numberInTeam}` над буфером, `complete = expectedCount>0 && present.size>=expectedCount`, `takenAt=sample.wallMs`, `trustedTakenAt`/`elapsedRealtimeAt`/`bootCount` из `TimeSample`), `attachLocation` (261–273: null-фикс = no-op, дроп `accuracy==Float.MAX_VALUE` и `gpsTimeMs<=0`, nanos→ms).
- `data/track/CurrentLocationProvider.kt` + `TrackModels.kt` (`RawFix`) — контракт one-shot GPS: `current(timeoutMs=8000) async -> RawFix?`, один свежий фикс или nil, **никогда не бросает**, свежесть обязательна (`MAX_FIX_AGE_MS=10_000`).
- `data/ScanFeedbackPlayer.kt` — success (beep_ok3 + 40 мс буз), failure (beep_err + двойной), neutral (только буз), `checkpointCompleteFanfare()`; `ui/scan/ScanScreen.kt` — таймер (тик `TIMER_TICK_MS=250`, финализация по истечении под мьютексом), фанфары через `COMPLETE_FANFARE_DELAY_MS=275` после success, автозакрытие «Готово!» `SUCCESS_HOLD_MS=3300`, UI-референс (CheckpointSheetCard, ChipGrid, ScanTimerStrip).
- `ui/team/BindChipSheet.kt` (states Waiting/PoolNotReady/NotInPool/AlreadyBound/Success) + хост-вайринг `MainActivity.kt` ~1792–1922 — различение «пул пуст, но синхронизирован» vs «не синхронизирован» (+ инлайн-`refreshMemberTags`), `scanMutex.tryLock` от дребезга, success-автозакрытие ~900 мс.
- WAV-ассеты: `app/src/main/res/raw/{beep_ok3,beep_err,checkpoint_mark_completed,mark_added_mario}.wav` (beep_scan не используется плеером, shutter — этап 7).
- **Android-тесты для зеркалирования:** startKpTake-часть `data/MarkRepositoryTest.kt` (DAO-часть `addMember`/`attachLocation` уже зеркалирована стором в этапе 2). Для `ScanModel` Android-зеркала нет (логика размазана по `MainActivity`) — тесты пишутся свежие.

## Development Approach

- **testing approach**: порт-TDD для чистой логики — Kotlin-тесты переносятся вместе с модулем в той же задаче (имена кейсов 1:1, header «Зеркало …»); для `ScanModel`/bind-флоу зеркала нет — тесты пишутся с нуля (regular: код → тесты в той же задаче) поверх **реальных** сторов на `AppDatabase.makeInMemory()` + фейков только для платформенных границ (`FakeChipScanner`, `FakeLocationProvider`, фидбек-рекордер — конвенция этапов 2–4);
- complete each task fully before moving to the next;
- make small, focused changes (коммит на задачу);
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task;
- **CRITICAL: all tests must pass before starting next task**;
- **CRITICAL: update this plan file when scope changes during implementation**.

## Testing Strategy

- **unit tests**: Swift Testing. Чистая логика — `kolco24Tests/Core/` (зеркала Kotlin + бонус-кейсы с пометкой). `ScanModelTests` — `kolco24Tests/App/` поверх in-memory БД, `@MainActor`, инжектированные `elapsedNowMs`/`sampleNow`-замыкания (управляемое время — окно тестируется без реальных задержек).
- **e2e**: автоматизированных нет. NFC/GPS не работают в симуляторе — сквозную проверку на устройстве делает пользователь вручную после завершения задач (10 сценариев — см. Post-Completion); в задачах остаётся только то, что проверяемо в симуляторе/сборкой.
- Прогон: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'` (нужен `Config/Secrets.xcconfig`; при флаки-имени — `id=<UDID>` из `xcrun simctl list devices available`).

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview

Раскладка по образцу существующих слоёв (`Net/` = платформенный адаптер, `Core/` = чистое, `App/` = `@Observable`-модели):

| iOS-файл | Содержимое | Kotlin-источник | Тесты |
|---|---|---|---|
| `Core/Marks/KpTake.swift` | чистый `makeKpTakeMark(...) -> Mark` | `MarkRepository.startKpTake` | `KpTakeTests` (зеркало) |
| `Core/Scan/ChipScanning.swift` | `TagReading`, протоколы `ChipScanning`/`ScanFeedbackPlaying` (швы) | — | через `ScanModelTests` |
| `Core/Track/CurrentLocation.swift` | `RawFix`, `protocol CurrentLocationProvider`, чистая санитизация/свежесть фикса | `CurrentLocationProvider.kt`, `TrackModels.kt` | `CurrentLocationTests` |
| `Nfc/MiFareTransport.swift` | `NfcTransport` поверх `sendMiFareCommand` | адаптер `readChipCode` | устройство |
| `Nfc/NfcChipScanner.swift` | длинная сессия + одноразовый режим, `AsyncStream<TagReading>` | reader-mode вайринг `MainActivity` | устройство |
| `App/ScanModel.swift` | хост-редьюсер: порт `onScanTag`+`ScanTakeState`, таймер, персист, GPS, фидбек, автозакрытия | `MainActivity.onScanTag` | `ScanModelTests` |
| `Location/CoreLocationProvider.swift` | one-shot GPS, разрешение | `FusedCurrentLocationProvider` | устройство |
| `Audio/ScanFeedbackPlayer.swift` + 4 WAV | звук + хаптики | `ScanFeedbackPlayer.kt` | ручная |
| `ScanSheet.swift` (переделка) | реальные данные через `ScanModel` | `ScanScreen.kt` (референс) | ручная + устройство |
| `BindChipSheet.swift` + `TeamView`/`TeamModel` | привязка браслетов | `BindChipSheet.kt` + хост-вайринг | `TeamModelTests`-дополнение |

**Grep-инварианты (расширение этапов 1–4):** `import CoreNFC` — только под `Nfc/`; `import CoreLocation` — только под `Location/`; `import AVFoundation`/`UIKit` (хаптики) — только под `Audio/`; по-прежнему никакого `UIKit`/`SwiftUI`/`GRDB` под `Core/`, `Model/`, `App/`-моделями (`ScanModel` зависит только от протоколов `Core/` и сторов). Новые подпапки под `kolco24/` попадают в таргет автоматически (synchronized group), WAV-файлы — в бандл как ресурсы; `project.pbxproj` трогается только ради `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription`.

## Technical Details

**Поведенческая спецификация порта (зеркалит Android, проверяется `ScanModelTests`):**
1. Два зеркальных состояния: чистая `ScanSession` (UI: КП, present, окно) + take-state для БД (`markId`, `checkpointId`, `expectedCount`, `buffer`, `present`, `snapshots: [Int: MarkMemberSnapshot]`, `lastScanAt` — полный набор `ScanTakeState`; `expectedCount` = размер ростера). Окно — по монотонному `sample.elapsedMs`, `isWindowExpired` из Core.
2. Обработка одного `TagReading`: `legendRepository.unlock(raceId, code)` → свежий снапшот `legendRepository.checkpointsSnapshot(raceId)` → `classifyTag(code:uid:unlock:bindings:checkpointsById:)`; `bindings` = `[uid: numberInTeam]` из наблюдаемых привязок; гвард «команда не выбрана» → `.badKp`.
3. `.kp`: окно истекло / `markId == nil` / другой КП → **новое взятие**: `makeKpTakeMark` (UUID, буфер сливается как `presentDetails` с дедупом по слоту, `complete`, `method:"nfc"`, времена из `TimeSample`) → `markStore.upsert`; сразу после — fire-and-forget GPS-attach (один раз на новое взятие). Повтор того же КП при живом окне — только перештамп окна (`lastScanAt = now`). На истечении окна буфер и снапшоты чистятся перед новым взятием.
4. `.member`: если окно истекло — **полный сброс take-state** до буферизации (`markId`/`checkpointId` в nil, `buffer`/`present`/`snapshots` чистятся — `MainActivity.kt:1428-1434`: участник после мёртвого окна открывает свежую сессию, не кредитуется старому взятию). Снапшот строится **до** проверок идемпотентности (`number` = `participantNumber` из привязки слота, 0 если нет); до КП — буфер (идемпотентный повтор — ранний выход, окно не трогается), после — гвард `present` + `markStore.addMember`. `lastScanAt = now` только для новых участников.
5. `.unboundChip`/`.badKp`: диагностика в UI + failure-фидбек, сессия и окно не меняются.
6. Записи в БД — в **неструктурированных `Task`** (аналог `applicationScope`): закрытие оверлея не обрывает начатый `upsert`/`addMember`; взятие живёт в БД с момента скана КП — смерть процесса его не теряет.
7. Последовательная обработка: `@MainActor` `ScanModel` + один `for await` по стриму заменяют Android-`scanMutex`.
8. Семпл `TrustedClock.sample()` берётся **до** чтения чипа (в `NfcChipScanner`, инжектированный `sampleNow`).
9. Не-K24 чип (`readRecord` → nil) — валидное чтение браслета, не ошибка. UID — через `normalizeNfcUid`.
10. Фидбек: `feedbackFor(event)`; на переходе incomplete→complete — обычный success, затем фанфары через 275 мс. Таймер: тик 250 мс по инжектированному `elapsedNowMs`; на истечении — автозакрытие (доп. записей в БД нет — марка уже персистована инкрементально); на `isComplete` — hold «Готово!» 3300 мс → автозакрытие.

**Жизненный цикл NFC-сессии (`NfcChipScanner`):**
- `start()` при открытии оверлея; `didDetect` → connect → UID → `MiFareTransport` + `readRecord` → `TagReading` в стрим → `restartPolling()`.
- Дебаунс того же UID ~1.5 с (физика reader mode в Android; редьюсер и так идемпотентен — дебаунс только от спама звуком).
- `didInvalidateWithError`: `sessionTimeout`/read-ошибка + хост говорит «окно живо и оверлей открыт» (замыкание `shouldRestart`) → новая сессия молча; отмена пользователем → событие наверх, оверлей закрывается штатно.
- `alertMessage` после каждого чтения: «Приложите чип КП» / «КП 32 · чипы 2/4» / «Чип не привязан».
- Одноразовый режим (для bind): один `TagReading` → invalidate.
- Мост async→sync для `NfcTransport.transceive`: `sendMiFareCommand` — колбэчный API; блокирующее ожидание семафором **не** на очереди колбэков CoreNFC.

**GPS:** `CoreLocationProvider` — `CLLocationManager.requestLocation()`, `kCLLocationAccuracyBest`, таймаут 8 с (race двух `Task`), свежесть ≤10 с, маппинг в `RawFix` (санитизация — чистый хелпер из `Core/Track`: дроп невалидной accuracy / `gpsTimeMs<=0`). Разрешение `requestWhenInUseAuthorization()` — один раз при первом открытии скан-оверлея (как в Android, заранее); отказ ничего не блокирует — `nil` → отметка без координат (сервер допускает).

**Звук:** `AVAudioPlayer` по плееру на клип; `AVAudioSession` `.playback` + `.mixWithOthers`/`.duckOthers` (писк должен пробиться сквозь музыку в наушниках). Хаптики (`UIImpactFeedbackGenerator`/`UINotificationFeedbackGenerator`) — best-effort: во время активной NFC-шторки система может их глушить, звук — главный канал.

**Bind-флоу (порт хост-вайринга):** короткая одноразовая сессия → `normalizeNfcUid` → пул: если пуст и `hasBeenSynced == false` → состояние «пул не готов» + инлайн `refreshMemberTags`; иначе `memberTagStore.findByUid` → `poolNumber`; `existing = memberChipBindingStore.findByUid(uid)` → **готовый** `decideBind` → исходы: `notInPool` (отказ), `alreadyBound` («Перепривязать?» → подтверждение → `reassign`), `readyToBind` (`reassign` + success, автозакрытие ~900 мс), `alreadyOnThisSlot` (инфо). Стор напрямую, без репозитория (YAGNI — конвенция этапа 4).

**Зависимости в графе:** `AppEnvironment` получает `trustedClock` (прод: `pair.clock`; inMemory: инжект с фейковыми провайдерами), `locationProvider: any CurrentLocationProvider`, `feedback: any ScanFeedbackPlaying` (прод-реализации подставляются в задачах 6–7; до того — no-op заглушки, чтобы граф собирался с задачи 3). **Шов сканера:** `ScanModel` принимает `any ChipScanning` через инициализатор/`start(scanner:)` — тесты задачи 4 передают `FakeChipScanner` (прод-тип ещё не существует); прод `NfcChipScanner` подставляется в задаче 8 через `AppModel.makeScanModel()` (App-слой может инстанцировать тип из `Nfc/` без `import CoreNFC` — один модуль). Bind-флоу живёт в `TeamModel` (отдельной bind-модели нет — см. Task 9); вьюхи не видят `env`.

## Implementation Steps

### Task 1: Чистая логика — makeKpTakeMark

**Files:**
- Create: `kolco24/Core/Marks/KpTake.swift`
- Create: `kolco24Tests/Core/KpTakeTests.swift`

- [ ] `makeKpTakeMark(id:raceId:teamId:checkpointId:number:cost:cpUid:cpCode:buffered:expectedCount:sample:) -> Mark` ← `MarkRepository.startKpTake` (127–167): UUID передаётся параметром (чистота), дедуп `buffered` по `numberInTeam`, `present` из дедупнутых слотов, `complete = expectedCount>0 && present.count>=expectedCount`, `method="nfc"`, `takenAt/updatedAt = sample.wallMs`, `trustedTakenAt/elapsedRealtimeAt/bootCount` из семпла
- [ ] `KpTakeTests` — зеркало startKpTake-части `MarkRepositoryTest.kt` (метаданные, дедуп двойного слота не флипает `complete` раньше времени, времена, пустой буфер, complete при полном буфере)
- [ ] прогнать тесты — must pass before task 2

### Task 2: Швы — ChipScanning + CurrentLocation

**Files:**
- Create: `kolco24/Core/Scan/ChipScanning.swift`
- Create: `kolco24/Core/Track/CurrentLocation.swift`
- Create: `kolco24Tests/Core/CurrentLocationTests.swift`

- [ ] `TagReading { code: Data?; uid: String; sample: TimeSample }`; `protocol ChipScanning` (`readings() -> AsyncStream<TagReading>`, `start()`/`stop()`, сигнал отмены пользователем/недоступности NFC); `protocol ScanFeedbackPlaying` (`play(_ kind: ScanFeedbackKind)`, `fanfare()`)
- [ ] `RawFix` (зеркало `TrackModels.kt`) + `protocol CurrentLocationProvider { current(timeoutMs:) async -> RawFix? }` + чистые хелперы: санитизация фикса (дроп невалидной accuracy, `gpsTimeMs<=0` — зеркало веток `MarkRepository.attachLocation`), проверка свежести (`MAX_FIX_AGE_MS=10_000`)
- [ ] `CurrentLocationTests` — чистые хелперы (валидный/несвежий/грязный фикс, граничные значения)
- [ ] прогнать тесты — must pass before task 3

### Task 3: AppEnvironment — trustedClock + зависимости этапа 5

**Files:**
- Modify: `kolco24/App/AppEnvironment.swift`

- [ ] `let trustedClock: TrustedClock`: прод из `pair.clock` (`makeShared` сейчас его теряет), `inMemory` — инжектируемый параметр с дефолтом на фейковых провайдерах
- [ ] `let locationProvider: any CurrentLocationProvider`, `let feedback: any ScanFeedbackPlaying` — с no-op заглушками в обеих фабриках (прод-реализации подставятся в задачах 6–7); inMemory — инжектируемые для тестов
- [ ] прогнать существующий сьют — must pass before task 4

### Task 4: App/ScanModel — хост-редьюсер скан-флоу

**Files:**
- Create: `kolco24/App/ScanModel.swift`
- Modify: `kolco24/App/AppModel.swift` (фабрика `makeScanModel()`)
- Create: `kolco24Tests/App/ScanModelTests.swift`

- [ ] состояние: `session: ScanSession?`, take-state (`markId`/`buffer`/`present`/`snapshots`/`lastScanAt`), `remainingSeconds`, `diagnostic: String?`, `completed`, `closeRequested` — по спецификации Technical Details §1–10
- [ ] сканер — через шов `any ChipScanning` (инициализатор/`start(scanner:)`): тесты передают `FakeChipScanner`, прод-тип появится только в task 5 и подключится в task 8
- [ ] обработка стрима `ChipScanning` (один `for await`): unlock → classifyTag → окно → персист (`makeKpTakeMark`→`upsert`; `addMember`) в неструктурированных `Task`; GPS-attach fire-and-forget один раз на новое взятие (`markStore.attachLocation`, nil-фикс = no-op — гвард в модели, стор принимает не-опционалы)
- [ ] фидбек (`feedbackFor` + фанфары 275 мс на incomplete→complete), таймер окна (тик 250 мс, инжектированный `elapsedNowMs`), автозакрытия (истечение окна; complete → hold 3300 мс), `shouldRestart`-замыкание для сканера
- [ ] `AppModel.makeScanModel()` — сборка из `env` (сторы, `legendRepository`, `trustedClock.sample`, `locationProvider`, `feedback`) + ростер/привязки выбранной команды
- [ ] `ScanModelTests` (in-memory БД, `FakeChipScanner`, `FakeLocationProvider`, фидбек-рекордер, управляемое время): КП→участники→complete (+фанфары); участники до КП (буфер→слив в present); истечение окна→новое взятие (буфер/снапшоты чищены); участник после истечения окна → полный сброс take-state, свежий буфер (не кредитуется мёртвому взятию); смена КП сбрасывает present; unbound/badKp не двигают окно + failure-фидбек; повторный участник идемпотентен и не перештамповывает окно; «закрытие шита» не обрывает персист; GPS-attach один раз, не трогает present; отказ GPS → mark без координат; гвард «команда не выбрана»
- [ ] прогнать тесты — must pass before task 5

### Task 5: Nfc/ — MiFareTransport + NfcChipScanner (замена спайка)

**Files:**
- Create: `kolco24/Nfc/MiFareTransport.swift`
- Create: `kolco24/Nfc/NfcChipScanner.swift`
- Delete: `kolco24/NFCReader.swift`
- Modify: `kolco24/ScanSheet.swift` (только убрать вызовы спайка — `NFCChipReader`/`NFCTestResultCard`; полная переделка — task 8)

- [ ] `MiFareTransport`: `NfcTransport.transceive` поверх `sendMiFareCommand`. ⚠️ Дедлок-ловушка: `readRecord` синхронно циклит `transceive` — семафорное ожидание обязано выполняться **не** на очереди колбэков CoreNFC, иначе wait заблокирует доставку колбэка
- [ ] чтение чипа = `normalizeNfcUid(identifier)` + чистый `readRecord`
- [ ] `NfcChipScanner` (`ChipScanning`): длинная сессия по Technical Details (restartPolling, дебаунс ~1.5 с, `shouldRestart`-рестарт по таймауту, `alertMessage`-прогресс, отмена наверх) + одноразовый режим для bind
- [ ] удалить спайк и **все шесть** его следов в `ScanSheet.swift`: `@State reader` (:24), `@State readResult` (:25 — тип `ChipReadResult` тоже исчезает), `NFCTestResultCard` (определение :192 + использование :74), оба вызова `reader.beginScan` (:131, :158); шит остаётся статичным моком до task 8
- [ ] прогнать сьют (сборка + все тесты зелёные); grep-инвариант: `import CoreNFC` только под `Nfc/`

### Task 6: Location/CoreLocationProvider + разрешение геолокации

**Files:**
- Create: `kolco24/Location/CoreLocationProvider.swift`
- Modify: `kolco24.xcodeproj/project.pbxproj` (`INFOPLIST_KEY_NSLocationWhenInUseUsageDescription`, обе конфигурации)
- Modify: `kolco24/App/AppEnvironment.swift` (прод-вайринг вместо заглушки)

- [ ] `CoreLocationProvider` (`CurrentLocationProvider`): `requestLocation()`, accuracy best, таймаут 8 с, свежесть/санитизация через хелперы task 2, отказ/ошибка → `nil`
- [ ] `INFOPLIST_KEY_NSLocationWhenInUseUsageDescription` («Координата в момент отметки на КП») в обе build-конфигурации
- [ ] запрос `requestWhenInUseAuthorization` при первом открытии скан-оверлея (хук — вызовется из `ScanSheet` в task 8)
- [ ] прод-вайринг `AppEnvironment.makeShared`
- [ ] прогнать сьют — must pass before task 7

### Task 7: Audio/ScanFeedbackPlayer + WAV-ассеты

**Files:**
- Create: `kolco24/Audio/ScanFeedbackPlayer.swift`
- Create: `kolco24/Audio/beep_ok3.wav`, `beep_err.wav`, `checkpoint_mark_completed.wav`, `mark_added_mario.wav` (копии из `kolco24_app_v2/app/src/main/res/raw/`)
- Modify: `kolco24/App/AppEnvironment.swift` (прод-вайринг)

- [ ] скопировать 4 WAV (beep_scan/shutter не нужны до этапов 6–7); проверить, что попали в бандл (synchronized group)
- [ ] `ScanFeedbackPlayer` (`ScanFeedbackPlaying`): `AVAudioPlayer` по плееру на клип, `.playback` + `.mixWithOthers`/`.duckOthers`; success/failure/neutral + fanfare; хаптики best-effort
- [ ] прод-вайринг `AppEnvironment.makeShared`
- [ ] прогнать сьют — must pass before task 8 (проверка звука на слух — Post-Completion)

### Task 8: Переделка ScanSheet на реальные данные

**Files:**
- Modify: `kolco24/ScanSheet.swift`
- Modify: `kolco24/MarksView.swift`

- [ ] удалить мок-массив `mockChips`; `ScanSheet` получает `ScanModel` (через `AppModel.makeScanModel()` из `MarksView`), `.task` — старт сканера + запрос гео-разрешения при первом открытии
- [ ] таймер-хиро от реального окна (`remainingSeconds`, «КП и ещё N чипов»), карточка КП «?» → номер + цена после `.kp`, грид слотов из реального ростера + `session.present`/привязок, строка диагностики (`badKp`/`unboundChip`)
- [ ] кнопки: «Сканировать чип» удалить; «Готово» (активна после КП) и «Отменить»; любое закрытие → `scanner.stop()` + no-op hook «flush uploads» (этап 6); автозакрытия из модели (`closeRequested`)
- [ ] превью с `FakeChipScanner` (прогон флоу в симуляторе без NFC)
- [ ] прогнать сьют — must pass before task 9 (device-смоук чтения — Post-Completion, пользователь проверяет сам)
- [ ] ➕ при необходимости — правки дизайна по факту системной шторки (весь ключевой статус в верхней трети экрана)

### Task 9: BindChipSheet + TeamView/TeamModel

**Files:**
- Create: `kolco24/BindChipSheet.swift`
- Modify: `kolco24/TeamView.swift` (замена заглушки «Привязать»)
- Modify: `kolco24/App/TeamModel.swift` (bind-флоу)
- Modify: `kolco24Tests/App/TeamModelTests.swift`

- [ ] bind-логика в `TeamModel` (порт хост-вайринга ~1792–1922): по `TagReading` одноразовой сессии → пул/`hasBeenSynced`/инлайн-refresh → `findByUid` → `decideBind` → состояние листа (waiting/poolNotReady/notInPool/alreadyBound/success) + `reassign`; фидбек success/failure
- [ ] `BindChipSheet` (SwiftUI): состояния из модели, «Перепривязать?» с подтверждением, success-автозакрытие ~900 мс; вход — тап по участнику без чипа в `TeamView` (заглушка-алерт удаляется)
- [ ] дополнение `TeamModelTests` (in-memory БД, `FakeChipScanner`): notInPool; readyToBind → `reassign` записал слот; alreadyBound → после подтверждения слот переехал (старый слот пуст); alreadyOnThisSlot; пул пуст + не синхронизирован → poolNotReady и дёрнут `refreshMemberTags` (по журналу `FakeTransport`)
- [ ] прогнать тесты — must pass before task 10

### Task 10: Верификация приёмки

- [ ] verify: все требования Overview реализованы (скан-флоу, GPS-фикс, звук/вибро, привязка), edge-кейсы спецификации §1–10 покрыты тестами
- [ ] полный сьют: `xcodebuild test ...` — зелёный
- [ ] grep-инварианты: CoreNFC/CoreLocation/AVFoundation только в своих папках; `Core`/`Model`/`App`-модели без UIKit/SwiftUI/GRDB
- [ ] сборка под device-destination (`generic/platform=iOS`) проходит — ручные проверки на устройстве делает пользователь (Post-Completion)

### Task 11: [Final] Документация

- [ ] обновить `CLAUDE.md`: слои `Nfc/`/`Location/`/`Audio/`, `ScanModel`, снятие заглушек `ScanSheet`/«Привязать», расширенные grep-инварианты
- [ ] отметить этап 5 выполненным в `docs/plans/android-port.md` (✅ + ссылка)
- [ ] перенести этот план в `docs/plans/completed/`

## Post-Completion

**Ручная приёмка на устройстве (делает пользователь; iPhone + K24-чип КП + браслеты из пула):**
1. Смоук чтения: FAB → скан чипа КП + браслета → взятие в БД, тайл в «Отметки».
2. Привязка: «Привязать» → скан браслета из пула → слот привязан (статус обновился сам); повтор → «уже на этом слоте»; на другой слот → предупреждение + перепривязка.
3. Отметка целиком: скан чипа КП (номер+цена, звук ok) → браслеты (слоты зеленеют, окно перештамповывается) → все → фанфары + «Готово!» → автозакрытие; тайл и очки в «Отметки».
4. «Участники до КП»: браслеты в буфер, потом КП — present слит.
5. Истечение окна (20 с) → автозакрытие; повторный скан того же КП → новое взятие.
6. 60-с лимит iOS: сканы раз в ~15 с дольше минуты — шторка мигнула (тихий рестарт), взятие не потерялось.
7. Непривязанный браслет / чужой чип → диагностика + звук ошибки, окно не двигается.
8. GPS: с разрешением `loc*`-поля заполнены; с отказом — взятие без координат.
9. Отмена системной NFC-шторки → оверлей закрылся, начатое взятие в БД осталось.
10. Звук: слышен с музыкой в наушниках (duck) и ведёт себя ожидаемо в беззвучном режиме.

**Manual verification (полевые условия):**
- Прогон на реальной гонке/тренировке: холодные руки, перчатки, скорость сканирования подряд идущих браслетов (дебаунс не мешает разным чипам).

**External / следующие этапы:**
- Взятия остаются локальными до этапа 6 (dual-target upload) — появление на сервере проверяется там.
- `neutral()`-фидбек в «простое» (Android: тап чипа вне оверлея) на iOS не существует — нет постоянного reader mode; не портируется.
