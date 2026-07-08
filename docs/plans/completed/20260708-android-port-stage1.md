# Этап 1 портирования: чистая логика (порт 1:1 + тесты)

Детализация этапа 1 из [android-port.md](../android-port.md). Этап 0 (инфраструктура) выполнен.

## Overview

Перенести из Android-приложения (`/Users/alff0x1f/src/kolco24_app_v2`, пакет `ru.kolco24.kolco24`) весь Android-free слой логики вместе с его JVM-тестами (~1.5k LOC исходников, ~160 тест-кейсов):

- `LegendCrypto` — оффлайн-крипто легенды (bid, HKDF, AES-GCM);
- HMAC-подпись запросов (`buildCanonical`/`sign`/`sha256Hex`);
- `TrustedClock` — доверенное время (серверный якорь + монотонные часы);
- `ScanSession`/`reduce`/`classifyTag` — state machine 20-секундного окна сканирования (+ сосед `ScanFeedback`);
- `decideBind` (привязка браслета), `decidePhotoTarget`/`resolvePhotoCheckpoint`/`filterCheckpointsByQuery` (фото-отметка);
- `nextSegmentId`/`shouldLiveUpload` (GPS-трек);
- формат чипа `K24` (`buildChipRecord`/`parseChipRecord`/`chipCodeHex`/… + `NfcTransport`);
- `normalizeNfcUid`, `pluralRu`.

Тесты зеркалируются 1:1 — это спецификация поведения. Бонус сверх Kotlin: сгенерированный из Python-референса сервера KAT-вектор для `LegendCrypto` (в Android-репо 4 таких теста стоят `@Ignore` с TODO).

После этапа: этапы 2–3 (БД, сеть) строятся поверх готовых доменных типов и чистых функций, UI не меняется.

## Context (from discovery)

- **Источник:** несколько «модулей» — это чистые top-level функции *внутри* Android-связанных файлов (`AppSignatureInterceptor.kt` — OkHttp, `TrackRecordingService.kt` — Service, `BindChipSheet.kt` — Compose): извлекаем только функции, обвязку не портируем.
- **Межэтапная зависимость:** `classifyTag` → `Checkpoint` + `UnlockOutcome` + `chipCodeHex`; `decideBind` → `MemberChipBinding`; `decidePhotoTarget` → `Mark` + `Checkpoint`. Решение: полные Swift-структуры (зеркало Room v5) уже сейчас, без суффикса `Entity`; этап 2 добавит им GRDB-конформансы.
- **Python-референс крипто:** `/Users/alff0x1f/src/kolco24/src/apps/mobile/legend_crypto.py` (+ `crypto.py`, `signing.py`) — первоисточник для KAT-вектора.
- **Тестовый таргет:** `kolco24Tests`, Swift Testing (`@Test`/`#expect`), хостится в приложении — `Config/Secrets.xcconfig` обязателен для прогона (см. CLAUDE.md).
- **Структура:** `kolco24/` — синхронизированная группа, новые подпапки попадают в таргет автоматически, `project.pbxproj` не трогаем.

## Development Approach

- **testing approach**: порт-TDD — Kotlin-тесты каждого модуля переносятся вместе с ним в той же задаче (сценарии и имена кейсов 1:1, отсебятину не добавлять);
- complete each task fully before moving to the next;
- make small, focused changes (коммит на модуль или пару мелких);
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task;
- **CRITICAL: all tests must pass before starting next task**;
- **CRITICAL: update this plan file when scope changes during implementation**.

## Testing Strategy

- **unit tests**: Swift Testing в `kolco24Tests/Core/…` — 16 файлов, ~160 кейсов, зеркало JUnit4-тестов из `app/src/test`. Тесты `TrustedClock` — async (`await` к actor), с фейковыми провайдерами времени. `ChipRecord` — с фейком `NfcTransport` (write/read, header-last commit).
- **KAT-вектора**: HMAC — уже инлайном в `SigningTest.kt:37`; LegendCrypto — сгенерировать (Task 3).
- **e2e**: нет. Живая сверка подписи с сервером (`GET /app/races/` → 200) — этап 3, когда появится `ApiClient`; здесь совместимость закрывается KAT-ами.
- Прогон: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'` (при флаки-имени — по `id=<UDID>`).

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview

**Раскладка** — идиоматичная для Swift, не зеркало Android-пакетов: всё чистое — под `kolco24/Core/`, доменные типы — под `kolco24/Model/`. Существующие 8 UI-файлов остаются в корне `kolco24/` — не трогать.

| iOS-файл | Kotlin-источник | Тесты (кейсов) |
|---|---|---|
| `Core/Util/HexBytes.swift` | идиома `"%02x".format` из разных файлов | через потребителей |
| `Core/Util/PluralRu.swift` | `data/PluralRu.kt` | `PointsPluralTest` (12) |
| `Core/Nfc/NfcUid.swift` | `data/NfcUid.kt` | `NfcUidTest` (4) |
| `Core/Api/Signing.swift` | верх `data/api/AppSignatureInterceptor.kt` | `SigningTest` (7 из 16; 9 `interceptor_*`-кейсов тестируют OkHttp-Interceptor → этап 3) |
| `Core/Crypto/LegendCrypto.swift` | `data/crypto/LegendCrypto.kt` | `LegendCryptoTest` (5) + `LegendCryptoSanityTest` (7) |
| `Model/Checkpoint.swift`, `Mark.swift`, `MemberChipBinding.swift`, `UnlockOutcome.swift` | `data/db/*Entity`, `data/LegendRepository.kt:197–209` | через потребителей |
| `Core/Nfc/ChipRecord.swift` | чистая часть `data/nfc/MifareUltralightWriter.kt` | `MifareUltralightWriterTest` (39) |
| `Core/Scan/ScanSession.swift` | `ui/scan/ScanSession.kt` | `ScanSessionTest` (25) + `ScanTagDecisionTest` (9) |
| `Core/Scan/ScanFeedback.swift` | `ui/scan/ScanFeedback.kt` | `ScanFeedbackTest` |
| `Core/Team/BindDecision.swift` | верх `ui/team/BindChipSheet.kt` | `BindChipDecisionTest` (7) |
| `Core/Marks/PhotoTarget.swift` | `data/marks/PhotoTarget.kt` целиком | `PhotoTargetTest` (12) + `ResolvePhotoCheckpointTest` + `FilterCheckpointsByQueryTest` |
| `Core/Track/Segments.swift` | верх `TrackRecordingService.kt` | `SegmentIdTest` (5) + `LiveUploadThrottleTest` (5) |
| `Core/Time/TrustedClock.swift` (+ `SystemClockProviders.swift`) | `data/time/TrustedClock.kt` | `TrustedClockTest` (24) |

**Ключевые решения:**
- Kotlin sealed-иерархии (`ScanEvent`, `BindOutcome`, `PhotoTarget`, `UnlockResult`/`UnlockOutcome`, `ClockStatus`) → Swift `enum` с associated values; data class → `struct` (`let`-поля, `Equatable`); `ByteArray` → `Data`/`[UInt8]` (`contentEquals` → `==`).
- `TrustedClock` — **actor** (не 1:1 класс): изоляция вместо `AtomicReference`+`synchronized`, все чтения снаружи через `await` (реальные вызыватели — подпись запросов, фиксация времени взятия — и так async). Вместо `StateFlow` — изолированное свойство `status` + `statusUpdates: AsyncStream<ClockStatus>` (для UI-баннера этапа 11).
- Порядок работ — от листьев к зависимым: утилиты → Signing → LegendCrypto → Model → ChipRecord → Scan/Bind/Photo/Segments → TrustedClock.

**Главная ловушка порта — hex от знаковых байтов:** Kotlin размазывает `"%02x".format(byte)` / `b.toInt() and 0xFF` по файлам; `%02x` на отрицательном `Int8` в Swift даст sign-extension. Решение: всё на `UInt8`/`Data` + единственный хелпер в `HexBytes.swift`.

## Technical Details

**LegendCrypto** (`enum LegendCrypto` как namespace, CryptoKit) — байт-в-байт совместимость с сервером:
- `bid(code:)` = `hex(SHA256(code))` первые 16 символов;
- `deriveWrapKey(code:)` = `HKDF<SHA256>` с **явной 32-байтовой нулевой солью** (не пустой — это разные ключи!), info `"kp-wrap-v1"` (ASCII), L=32;
- `open(key:ivB64:ctB64:aad:)` = `AES.GCM.SealedBox(nonce:ciphertext:tag:)` — iv 12 байт, хвостовые 16 байт `ct` отрезаются как tag (**не** `combined:` — тот ждёт nonce в начале); `open` **бросает** (как Kotlin `GeneralSecurityException`), ловит и превращает в `.failed` только `unlock` — сплит сохранить;
- `unlock(code:tag:encById:)` → `UnlockResult.{revealed|identityOnly|failed}`; любая ошибка (битый base64 — Kotlin там okio `decodeBase64`, у нас `Data(base64Encoded:)`; tag mismatch; кривой JSON) → `.failed`, наружу не бросается; отдельная неочевидная ветка: пустой `revealed` при непустом `bundle` → `.failed("legend may be stale")` (`LegendCrypto.kt:113–115`) — не схлопнуть в общий catch; `JSONDecoder`: ключи-строки → `Int`, незнакомые поля игнорируются (дефолт `JSONDecoder`), plaintext `{cost: Int, description: String?}`.

**Signing** — свободные функции: `sha256Hex(_:)`; `buildCanonical(method:fullPath:ts:bodyHash:)` = 4 части через `\n`, метод uppercase; `sign(secret:canonical:)` = HMAC-SHA256 lower-hex; `EMPTY_BODY_SHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"`. KAT: `sign("test-secret-123", <canonical из API.md>)` = `cf1c254fb2eac6c7efde1cff6efe9553878370299cd60a42be4d2105a8072588`.

**TrustedClock** (actor):
- API: `trusted() -> Int64?`, `trustedAt(elapsedAt:bootAt:)`, `sample() -> TimeSample`, `signingSeconds() -> Int64`, `onServerTime(serverMs:anchorElapsed:wallNow:bootNow:)`, `recomputeStatus()`; типы `ClockAnchor`, `TimeSample`, `ClockStatus.{noSync|ok|skewed(skewMs:)}`; `SKEW_THRESHOLD_MS = 60_000`;
- инъекция замыканий: `elapsedProvider`, `wallProvider`, `bootCountProvider`, `persist`/`persisted` (персистенция якоря — `ClockAnchorStore` этапа 2, в тестах in-memory);
- продовые провайдеры в `SystemClockProviders.swift`: elapsed = `mach_continuous_time()` в мс (аналог `elapsedRealtime()`, идёт во сне; `systemUptime`/`CLOCK_UPTIME_RAW` во сне стоят — не подходят), wall = `Date().timeIntervalSince1970 * 1000`, bootCount = всегда `nil` (аналога `Settings.Global.BOOT_COUNT` на iOS нет; Kotlin-логика уже трактует `null` как «нет свидетельства ребута» и ловит ребут по регрессии монотонных часов относительно сохранённого якоря). Ветки тестов с `bootCount != nil` тоже переносятся — провайдер инъектируется.

**ChipRecord**: `MAGIC = "K24"`, `CHIP_TYPE_KP = 0x1`, `CHIP_FORMAT_VERSION = 0x1`, packed-байт `(version << 4) | type`, `CHIP_CODE_BYTES = 16`, `CHIP_RECORD_BYTES = 20`; `protocol NfcTransport` (Kotlin `fun interface`) + `writeRecord`/`readRecord` поверх него (header-last commit — тестируется фейком); `android.nfc`-обвязку (`writeChipCode`/`readChipCode`/`readChipVersion`) не портировать — CoreNFC-адаптер будет в этапе 5.

**Константы-окна**: `SCAN_WINDOW_MS = 20_000` (ScanSession), `PHOTO_ATTACH_WINDOW_MS = 180_000` (PhotoTarget), `LIVE_UPLOAD_MIN_INTERVAL_MS = 600_000` (Segments).

**Генерация KAT-вектора** (Task 3): одноразовый Python-скрипт в scratchpad. Импортируемый движок — серверный `crypto.py` (`seal`, `derive_wrap_key`); `bid` (однострочник `sha256(code).hexdigest()[:16]` инлайном в `legend_crypto.py:128`) и сборка bundle-карты воспроизводятся в скрипте — они Django-ORM-связаны и напрямую не импортируются. Фиксированный `code` → печатает `bid`, `wrapKey` (hex), `iv`/`ct` (base64), `aad`, plaintext-JSON. Константы зашиваются в `LegendCryptoTests.swift`.

## Implementation Steps

### Task 1: Каркас Core/ + утилиты-листья (HexBytes, PluralRu, NfcUid)

**Files:**
- Create: `kolco24/Core/Util/HexBytes.swift`
- Create: `kolco24/Core/Util/PluralRu.swift`
- Create: `kolco24/Core/Nfc/NfcUid.swift`
- Create: `kolco24Tests/Core/PluralRuTests.swift`
- Create: `kolco24Tests/Core/NfcUidTests.swift`

- [x] `HexBytes.swift`: hex-хелперы (`Data`/`[UInt8]` → lower-hex строка; hex-строка → байты, аналог `digitToInt(16)` из `chipCodeFromHex`) — единственное место `%02x`-идиомы
- [x] `PluralRu.swift`: `pluralRu(count:one:few:many:)` ← `data/PluralRu.kt` (русские плюралы, отрицательные через `abs`); плюс производные хелперы `pointsWord`/`pointsLabel`/`segmentsWord`/`relativeTimeRu` ← `data/track/PointsPlural.kt` (нужны тесту `PointsPluralTest`)
- [x] `NfcUid.swift`: `normalizeNfcUid(_:)` ← `data/NfcUid.kt` (uppercase hex по байтам)
- [x] `PluralRuTests` ← `data/track/PointsPluralTest.kt` (12 кейсов)
- [x] `NfcUidTests` ← `data/NfcUidTest.kt` (4 кейса; заодно покрывают hex-хелперы)
- [x] прогнать тесты + убедиться, что новые подпапки попали в таргеты без правки pbxproj — must pass before task 2

### Task 2: Signing (HMAC-подпись запросов)

**Files:**
- Create: `kolco24/Core/Api/Signing.swift`
- Create: `kolco24Tests/Core/SigningTests.swift`

- [x] `Signing.swift`: `sha256Hex(_:)`, `buildCanonical(method:fullPath:ts:bodyHash:)`, `sign(secret:canonical:)`, `EMPTY_BODY_SHA256` ← верх `data/api/AppSignatureInterceptor.kt` (только 4 декларации; сам `Interceptor` OkHttp-связан — не портировать, URLSession-аналог будет в этапе 3)
- [x] `SigningTests` ← `data/api/SigningTest.kt`: 7 кейсов чистых функций (`buildCanonical` ×2, `sign` ×2, `sha256Hex` ×2, канонизация POST-тела), включая KAT `cf1c254f…` и `sha256Hex(Data()) == EMPTY_BODY_SHA256`; остальные 9 `interceptor_*`-кейсов тестируют OkHttp-Interceptor — переносятся на этапе 3 вместе с URLSession-аналогом
- [x] дополнительно сверить Swift-подпись с выводом python-команды из коммента в `SigningTest.kt:37` (разово, руками) — совпало: `cf1c254fb2eac6c7efde1cff6efe9553878370299cd60a42be4d2105a8072588`
- [x] прогнать тесты — must pass before task 3

### Task 3: LegendCrypto + серверный KAT-вектор

**Files:**
- Create: `kolco24/Core/Crypto/LegendCrypto.swift`
- Create: `kolco24Tests/Core/LegendCryptoTests.swift`
- Create: `kolco24Tests/Core/LegendCryptoSanityTests.swift`
- Create (scratchpad, вне git): `gen_legend_kat.py`

- [x] `LegendCrypto.swift` ← `data/crypto/LegendCrypto.kt`: `bid`, `deriveWrapKey` (HKDF, нулевая 32-байтовая соль, info `"kp-wrap-v1"`), `open` (SealedBox со сплитом tag), `unlock`; типы `EncBlob`, `UnlockTag`, `RevealedCheckpoint`, `UnlockResult` (см. Technical Details — все крипто-нюансы там)
- [x] сгенерировать KAT-вектор скриптом поверх серверного `/Users/alff0x1f/src/kolco24/src/apps/mobile/crypto.py` (импорт `seal`/`derive_wrap_key`; `bid` и bundle-карта — воспроизведённые однострочники из `legend_crypto.py`, см. Technical Details): `code → bid, wrapKey, iv/ct (b64), aad, plaintext`
- [x] `LegendCryptoTests` ← `data/crypto/LegendCryptoTest.kt` (5 кейсов): 4 `@Ignore`-заглушки заменить реальными константами вектора + кейс «tampered ct → failed»
- [x] `LegendCryptoSanityTests` ← `LegendCryptoSanityTest.kt` (7 кейсов, локальный round-trip: seal тест-хелпером → open)
- [x] прогнать тесты — must pass before task 4

### Task 4: Доменные типы (Model/)

**Files:**
- Create: `kolco24/Model/Checkpoint.swift`
- Create: `kolco24/Model/Mark.swift`
- Create: `kolco24/Model/MemberChipBinding.swift`
- Create: `kolco24/Model/UnlockOutcome.swift`

- [x] `Checkpoint`, `Mark`, `MemberChipBinding` — полные structs, зеркало Room v5 (`data/db/*Entity`): `let`-поля, camelCase, опционалы вместо nullable, `Equatable`; без суффикса `Entity`, без GRDB (конформансы — этап 2) (плюс `MarkMemberSnapshot` — вложенный value-тип `MarkEntity`; `Long`→`Int64`, `Float`→`Float`)
- [x] `UnlockOutcome` — enum ← sealed из `data/LegendRepository.kt:196–209`, **4 кейса**: `revealed(checkpointId: Int, checkpointIds: [Int])` / `identityOnly(checkpointId: Int)` / `unknown` / `failed(reason: String)` (не путать с `RevealedCheckpoint(id:cost:description:)` из `LegendCrypto` — это другой тип; `classifyTag` матчит все 4 кейса, включая `unknown → badKp`)
- [x] сборка проходит; тесты: типы без логики — покрываются потребителями в задачах 5–7 (аналогично Task 1 этапа 0)

### Task 5: ChipRecord (формат чипа K24)

**Files:**
- Create: `kolco24/Core/Nfc/ChipRecord.swift`
- Create: `kolco24Tests/Core/ChipRecordTests.swift`

- [x] чистые функции ← `data/nfc/MifareUltralightWriter.kt`: `buildChipRecord(type:code:)`, `parseChipRecord(pages:)`, `chipCodeHex(_:)`, `chipCodeFromHex(_:)`, `chipModelFromVersion(_:)` + константы (`MAGIC`, packed-байт и т.д.) — `buildChipRecord` сделан `throws` (Swift-идиома вместо `require`/`IllegalArgumentException`: precondition-trap не тестируется через Swift Testing)
- [x] `protocol NfcTransport` + `writeRecord`/`readRecord` поверх него (header-last commit); `android.nfc`-обвязку не портировать
- [x] `ChipRecordTests` ← `MifareUltralightWriterTest.kt` (39 кейсов, включая фейковый транспорт: порядок записи страниц, обрыв, read-back mismatch)
- [x] прогнать тесты — must pass before task 6

### Task 6: Логика сканирования (ScanSession + ScanFeedback)

**Files:**
- Create: `kolco24/Core/Scan/ScanSession.swift`
- Create: `kolco24/Core/Scan/ScanFeedback.swift`
- Create: `kolco24Tests/Core/ScanSessionTests.swift`
- Create: `kolco24Tests/Core/ScanTagDecisionTests.swift`
- Create: `kolco24Tests/Core/ScanFeedbackTests.swift`

- [x] `ScanSession.swift` ← `ui/scan/ScanSession.kt`: `struct ScanSession` (+ `empty(now:)`), `enum ScanEvent` (`kp`/`member`/`unboundChip`/`badKp`), `reduce(session:event:now:)`, `isWindowExpired(lastScanAt:now:)` (`SCAN_WINDOW_MS = 20_000`), `isComplete(session:rosterSize:)`, `classifyTag(code:uid:unlock:bindings:checkpointsById:)` (зависимости: `UnlockOutcome`, `Checkpoint`, `chipCodeHex` — уже готовы)
- [x] `ScanFeedback.swift` ← `ui/scan/ScanFeedback.kt`: `enum ScanFeedbackKind` + `feedbackFor(event:)`
- [x] `ScanSessionTests` ← `ScanSessionTest.kt` (25 кейсов: окно, дедуп, порядок событий)
- [x] `ScanTagDecisionTests` ← `ScanTagDecisionTest.kt` (9 кейсов classifyTag)
- [x] `ScanFeedbackTests` ← `ScanFeedbackTest.kt` (5 кейсов)
- [x] прогнать тесты — must pass before task 7

### Task 7: Решатели: BindDecision + PhotoTarget + Segments

**Files:**
- Create: `kolco24/Core/Team/BindDecision.swift`
- Create: `kolco24/Core/Marks/PhotoTarget.swift`
- Create: `kolco24/Core/Track/Segments.swift`
- Create: `kolco24Tests/Core/BindChipDecisionTests.swift`
- Create: `kolco24Tests/Core/PhotoTargetTests.swift`
- Create: `kolco24Tests/Core/ResolvePhotoCheckpointTests.swift`
- Create: `kolco24Tests/Core/FilterCheckpointsByQueryTests.swift`
- Create: `kolco24Tests/Core/SegmentIdTests.swift`
- Create: `kolco24Tests/Core/LiveUploadThrottleTests.swift`

- [x] `BindDecision.swift` ← чистый верх `ui/team/BindChipSheet.kt`: `struct SlotKey`, `decideBind(uid:poolNumber:existing:currentSlot:)`, `enum BindOutcome` (`notInPool`/`alreadyBound`/`readyToBind`/`alreadyOnThisSlot`); Compose-часть не портировать
- [x] `PhotoTarget.swift` ← `data/marks/PhotoTarget.kt` целиком: `decidePhotoTarget(marks:nowMs:)` (`PHOTO_ATTACH_WINDOW_MS = 180_000`), `enum PhotoTarget` (`attachTo`/`askNumber`), `resolvePhotoCheckpoint(number:legend:)`, `filterCheckpointsByQuery(legend:query:)`
- [x] `Segments.swift` ← чистый верх `TrackRecordingService.kt`: `nextSegmentId(current:wasTearingDown:mint:)`, `shouldLiveUpload(nowElapsed:lastUploadElapsed:minIntervalMs:)` (`LIVE_UPLOAD_MIN_INTERVAL_MS = 600_000`); сам Service не портировать
- [x] тесты ← `BindChipDecisionTest.kt` (7), `PhotoTargetTest.kt` (12), `ResolvePhotoCheckpointTest.kt` (4), `FilterCheckpointsByQueryTest.kt` (7), `SegmentIdTest.kt` (5), `LiveUploadThrottleTest.kt` (5)
- [x] прогнать тесты — must pass before task 8 (весь `xcodebuild test` зелёный: `** TEST SUCCEEDED **`)

### Task 8: TrustedClock (actor)

**Files:**
- Create: `kolco24/Core/Time/TrustedClock.swift`
- Create: `kolco24/Core/Time/SystemClockProviders.swift`
- Create: `kolco24Tests/Core/TrustedClockTests.swift`

- [x] `actor TrustedClock` ← `data/time/TrustedClock.kt` (237 LOC): API, типы и статус — см. Technical Details; поведенческая логика (якорь, регрессия монотонных часов, скью) — 1:1
- [x] `statusUpdates: AsyncStream<ClockStatus>` вместо `StateFlow` (потребитель — баннер этапа 11); дедуп равных значений вручную (как `MutableStateFlow`), буфер `.bufferingNewest(1)`
- [x] `SystemClockProviders.swift`: elapsed = `mach_continuous_time()` в мс (+ timebase-конверсия), wall, bootCount = `nil`; плюс `makeClock(...)`-фабрика
- [x] `TrustedClockTests` ← `TrustedClockTest.kt` (24 кейса, async, фейковые провайдеры + in-memory persist; ветки `bootCount != nil` тоже). ⚠️ В 3 кейсах (`trustedAt_pastFix`, `trustedAt_preAnchorPoint`, `sample_isConsistentSnapshot`) `#expect(optional == <арифметика-литералов>)` даёт ложный провал только в полном прогоне сьюта под Xcode 26 SDK Swift Testing (значение корректно — подтверждено диагностикой); обойдено вынесением ожидаемого в `let expected: Int64`. `persist` — throwing-замыкание (`try?`) для порта кейса `persistThrows`.
- [x] прогнать тесты — must pass before task 9 (весь `xcodebuild test` зелёный: `** TEST SUCCEEDED **`, 0 упавших кейсов)

### Task 9: Verify acceptance criteria

- [x] полный `xcodebuild test` зелёный, включая существовавшие `SecretsTests`/`InfoPlistTests`/`GRDBSmokeTests` — `** TEST SUCCEEDED **`, 0 упавших; 193 пройденных кейса (187 unit + 6 UI-прогонов), в т.ч. `SecretsTests` (7), `InfoPlistTests` (3), `GRDBSmokeTests` (1); iPhone 16 sim `9D9F760F-...`
- [x] `grep -rn "import UIKit\|import SwiftUI" kolco24/Core kolco24/Model` — пусто (exit 1, чистая логика без UI-фреймворков)
- [x] UI не тронут: `git diff --stat main...HEAD -- kolco24/` — только новые файлы под `Core/`/`Model/` (17 файлов, +1538); ни один из 8 корневых UI-файлов не изменён
- [x] сверка покрытия: 16/16 Kotlin-тест-файлов таблицы имеют Swift-зеркало с совпадающим числом кейсов (см. таблицу ниже); расхождения объяснены: `SigningTest` 7/16 (9 `interceptor_*` → этап 3), `LegendCryptoTest` — 5 активных `@Test` (6 `@Ignore` в Android, из них 4 вектор-теста в Swift заполнены серверным KAT)
- [x] KAT-вектор LegendCrypto получен из серверного движка: `seal`/`derive_wrap_key` импортированы из `crypto.py` (строки 19/40), воспроизведены только неимпортируемые однострочники (`bid` из `legend_crypto.py`, bundle-карта); константы в `LegendCryptoTests.swift` — серверные (`bid=be45cb2605bf36be`, `wrapKey=d60113b6…c4d51a99`)

**Сверка покрытия (Task 9):**

| Kotlin (@Test / @Ignore) | Swift-зеркало (@Test) | Статус |
|---|---|---|
| `PointsPluralTest` (12) | `PluralRuTests` (12) | ✅ |
| `NfcUidTest` (4) | `NfcUidTests` (4) | ✅ |
| `SigningTest` (16) | `SigningTests` (7) | ✅ 9 `interceptor_*` → этап 3 |
| `LegendCryptoTest` (5 / 6 `@Ignore`) | `LegendCryptoTests` (5) | ✅ 4 вектор-теста заполнены серверным KAT |
| `LegendCryptoSanityTest` (7) | `LegendCryptoSanityTests` (7) | ✅ |
| `MifareUltralightWriterTest` (39) | `ChipRecordTests` (39) | ✅ |
| `ScanSessionTest` (25) | `ScanSessionTests` (25) | ✅ |
| `ScanTagDecisionTest` (9) | `ScanTagDecisionTests` (9) | ✅ |
| `ScanFeedbackTest` (5) | `ScanFeedbackTests` (5) | ✅ |
| `BindChipDecisionTest` (7) | `BindChipDecisionTests` (7) | ✅ |
| `PhotoTargetTest` (12) | `PhotoTargetTests` (12) | ✅ |
| `ResolvePhotoCheckpointTest` (4) | `ResolvePhotoCheckpointTests` (4) | ✅ |
| `FilterCheckpointsByQueryTest` (7) | `FilterCheckpointsByQueryTests` (7) | ✅ |
| `SegmentIdTest` (5) | `SegmentIdTests` (5) | ✅ |
| `LiveUploadThrottleTest` (5) | `LiveUploadThrottleTests` (5) | ✅ |
| `TrustedClockTest` (24) | `TrustedClockTests` (24) | ✅ |

### Task 10: [Final] Документация

**Files:**
- Modify: `docs/plans/android-port.md`
- Modify: `CLAUDE.md`

- [x] в `android-port.md` пометить этап 1 ✅ со ссылкой на этот план (по образцу этапа 0)
- [x] в `CLAUDE.md` описать новую структуру (`Core/`, `Model/`), actor `TrustedClock`, KAT-вектора и главную ловушку hex/знаковых байтов
- [x] переместить этот план в `docs/plans/completed/` (поправить ссылку в шапке на `../android-port.md`)

## Post-Completion

**Manual verification:**
- живая сверка подписи с реальным сервером — подписанный `GET /app/races/` → 200 — на этапе 3 (когда появится `ApiClient` на URLSession);
- поведение `mach_continuous_time()` во сне устройства — проверить на реальном железе на этапе 5 (в симуляторе сон не воспроизводится).

**External system updates:**
- сгенерированный KAT-вектор LegendCrypto можно отдать в Android-репо (`kolco24_app_v2`) — там 4 теста стоят `@Ignore` с `TODO(server-vector)`; вне скоупа этого плана.
