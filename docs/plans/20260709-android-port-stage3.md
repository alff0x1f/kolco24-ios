# Этап 3 портирования: сеть и синхронизация

Детализация этапа 3 из [android-port.md](android-port.md). Этапы 0 (инфраструктура), 1 (чистая логика) и 2 (БД/хранилища) выполнены.

## Overview

Перенести сетевой слой и sync-репозитории Android-приложения (`/Users/alff0x1f/src/kolco24_app_v2`, пакет `data/api/` + `data/*Repository.kt`) на URLSession:

- `ApiClient` — единая точка `/app/`-API: подпись каждого запроса 6 заголовками (`X-App-Platform: ios`), якорение `TrustedClock` по заголовку `Date`, retry-once на 403 для GET, условные GET с ETag/304;
- result-типы `FetchResult`/`PostResult`/`RefreshResult` — ошибки не бросаются;
- 4 sync-репозитория (Race/Team/Legend/MemberTags): паттерн «persist → потом ETag», кросс-origin-инвалидация, pin-guard; `LegendRepository.unlock` поверх `LegendCrypto` этапа 1;
- `SyncSource` (cloud/local) закладывается в API репозиториев сразу; `SyncCoordinator`/lease/полный LAN-режим — этап 9;
- тесты: зеркала ~148 JVM-кейсов Android + smoke против живого сервера (подписанный `GET /app/races/` → 200).

**Ключевая адаптация под платформу (требование: не 1в1 из Kotlin).** У URLSession нет OkHttp-интерсепторов — вместо цепочки `AppSignatureInterceptor` + `ServerTimeInterceptor` подпись, якорение времени и 403-retry складываются в явный пайплайн внутри `ApiClient`; транспорт инжектируется замыканием (идиома `TrustedClock`), sealed-интерфейсы становятся enum'ами, kotlinx.serialization → `Codable`. **Поведенческий контракт с сервером при этом переносится точно** — канонические строки, порядок «данные → ETag», правила retry и RTT-фильтры — это спецификация, зафиксированная Android-тестами.

После этапа: этап 4 подключает UI к реальным данным (репозитории + observation'ы этапа 2 готовы), этап 6 переиспользует `post`-пайплайн для загрузки, этап 9 подставляет lease в `isRacePinned`-seam.

## Context (from discovery)

- **Источник правды по контракту:** `kolco24_app_v2/docs/design/API.md` (`docs/API.md` **не существует** — ссылка в мастер-плане устарела). Upload-контракт: `docs/design/UPLOAD.md` (этап 6). Серверный референс подписи: `src/apps/mobile/signing.py`.
- **Kotlin-источники** (относительно `app/src/main/java/ru/kolco24/kolco24/`): `data/api/ApiClient.kt`, `data/api/AppSignatureInterceptor.kt`, `data/api/ServerTimeInterceptor.kt`, `data/api/dto/*.kt`, `data/RaceRepository.kt`, `data/TeamRepository.kt`, `data/LegendRepository.kt`, `data/MemberTagsRepository.kt`, `data/SyncSource.kt`; вайринг — `AppContainer.kt`.
- **Эндпоинты (все GET, без query-параметров):** `/app/races/`, `/app/race/<id>/teams/`, `/app/race/<id>/legend/`, `/app/race/<id>/member_tags/` (все ETag/304), `/app/race/<id>/sync/` (без ETag). Завершающий слэш обязателен — он входит в подписанный путь. Плохая подпись → единообразный `403 {"detail":"Forbidden"}`; окно replay ±300 с.
- **Готово из этапов 1–2:** `Core/Api/Signing.swift` (`buildCanonical`/`sign`/`sha256Hex`/`EMPTY_BODY_SHA256`), `TrustedClock` (+`makeDefault()`), `InstallId`, все store'ы (`replaceAllForRace`, preserve-reveal у `CheckpointStore`, `SyncMetaStore` c `getEtag`/`upsert`/`deleteEtag`/`observeEtagsExist`), `LegendCrypto` + KAT-векторы, `Secrets` (apiBaseURL, appKeyId, appSecret, localAPIBaseURL). ATS уже разрешает cleartext в LAN.
- **Android-клиенты — два экземпляра:** cloud (10 с таймауты, оба интерсептора) и LAN (3 с — офлайн-фейл быстрый; **без** `ServerTimeInterceptor` — LAN-хост никогда не якорит доверенное время). Без HTTP-кэша — заголовок `Date` всегда живой.
- **Android-тесты для зеркалирования** (`app/src/test/java/ru/kolco24/kolco24/data/`): `api/ApiClientTest.kt` (48), `api/ServerTimeInterceptorTest.kt` (9), `RaceRepositoryTest.kt` (12), `TeamRepositoryTest.kt` (18), `LegendRepositoryTest.kt` (29), `MemberTagsRepositoryTest.kt` (32). Матрица 403-retry из `api/SigningTest.kt` (в этапе 1 пропущена — retry жил в интерсепторе) закрывается в `ApiClientTests`. `sync/SyncCoordinatorTest.kt` (24) — этап 9, не зеркалируется сейчас.
- **Синхронизированная группа:** новые подпапки `kolco24/Net/`, `kolco24/Data/Repositories/`, `kolco24Tests/Net/` попадают в таргеты автоматически, `project.pbxproj` не трогаем.

## Development Approach

- **testing approach**: порт-TDD — Android-тесты каждого модуля переносятся вместе с ним в той же задаче (сценарии и имена кейсов 1:1, header-комментарий «Зеркало …»); бонус-тесты сверх Kotlin помечаются `// MARK: - БОНУС-тесты`;
- complete each task fully before moving to the next;
- make small, focused changes (коммит на задачу или пару мелких);
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task;
- **CRITICAL: all tests must pass before starting next task**;
- **CRITICAL: update this plan file when scope changes during implementation**.

## Testing Strategy

- **unit tests**: Swift Testing. Сетевые — `kolco24Tests/Net/` с фейковым транспортом-замыканием (очередь заготовленных `(Data, HTTPURLResponse)` + журнал перехваченных `URLRequest`) — замена MockWebServer, без сети и глобального состояния. Репозиторные — `kolco24Tests/Data/Repositories/` поверх **реальных** store'ов над `AppDatabase.makeInMemory()` (конвенция этапа 2 — без фейков) + фейковый транспорт.
- **подпись в тестах** проверяется пересчётом теми же `Core/Api`-функциями (`buildCanonical`/`sign`) над перехваченным запросом — независимая сверка, как в `SigningTest.kt`.
- **smoke**: `LiveServerSmokeTests`, gated через env `LIVE_API_SMOKE` — единственная проверка прод-`URLSession`-транспорта (см. Technical Details).
- **e2e**: нет. Живой UI поверх реальных данных — этап 4.
- Прогон: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'` (нужен `Config/Secrets.xcconfig`; при флаки-имени — `id=<UDID>` из `xcrun simctl list devices available`).

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview

**Архитектура — пайплайн + транспорт-замыкание (решение брейншторма), вместо OkHttp-интерсепторов:**

1. `Net/ApiClient.swift` — структура, зависимости — значения и замыкания: `baseURL` (без завершающего `/`), `keyId`/`secret`/`installId`/`appVersion`, `nowSeconds: () async -> Int64` (= `trustedClock.signingSeconds`), `elapsedNowMs: () -> Int64` (RTT; синхронное — обёртка `mach_continuous_time`), `onServerTime: ((ServerTimeSample) async -> Void)?` (**nil у LAN-клиента**), `tokenProvider: () -> String?`, `transport: (URLRequest) async throws -> (Data, HTTPURLResponse)`. **`nowSeconds`/`onServerTime` — обязательно `async`-замыкания с inline-`await` в пайплайне:** `TrustedClock` — actor, его `signingSeconds()`/`onServerTime(…)` изолированы; fire-and-forget (`Task { await … }`) внутри синхронного замыкания молча сломал бы порядок самолечения 403 (retry-решение прочитало бы `nowSeconds()` до завершения перезаякоривания).
2. Пайплайн одного запроса (заменяет оба интерсептора, порядок = порядку OkHttp-цепочки): построить `URLRequest` → подписать 6 заголовками → `transport` с замером RTT → разобрать `Date` → `onServerTime` → при `403 && GET && nowSeconds() != usedTs` переподписать и повторить **ровно один раз** (самолечение clock-skew: якорь уже обновлён на предыдущем шаге). POST не ретраится никогда.
3. `Core/Time/ServerTimeSampler.swift` — чистый разбор `Date`-заголовка + RTT-правила (порт `ServerTimeInterceptor.kt`), тестируется отдельно; `ApiClient` только вызывает.
4. `Net/ApiResults.swift` — `FetchResult<T>`/`PostResult<T>` enum'ами; `RefreshResult` — рядом с репозиториями. `Net/Dto/` — 5 Codable-файлов, чисто проводные типы; маппинг в `Model/`-структуры делают репозитории.
5. `Data/Repositories/` — 4 struct-репозитория по образцу store'ов; `SyncSource` — параметр `refresh…(source: .cloud)`; `isRacePinned: (Int64) -> Bool`-seam (сейчас всегда `false`, этап 9 подставит lease). `SyncCoordinator`, lease, `LocalModeOutcome` — **не делать**.
6. Прод-транспорт — обёртка над `URLSession` (ephemeral, без кэша); фабрика двух клиентов cloud/LAN. Композиция в приложение (аналог `AppContainer`) — этап 4; этап 3 сдаёт детали + фабрику.
7. Generic `post`-метод в пайплайне делается сейчас (потребители — этап 6): без него не перенести тестовую матрицу «POST не ретраится» и «тело хэшируется байт-в-байт».

**Раскладка:**

| iOS-файл | Kotlin-источник | Тесты |
|---|---|---|
| `Core/Sync/SyncSource.swift` | `data/SyncSource.kt` | через репозитории |
| `Core/Time/ServerTimeSampler.swift` | `data/api/ServerTimeInterceptor.kt` | `ServerTimeSamplerTests` (9) |
| `Net/ApiResults.swift` | sealed-типы из `data/api/ApiClient.kt` | через `ApiClientTests` |
| `Net/Dto/RacesResponse\|TeamsResponse\|LegendResponse\|MemberTagsResponse\|SyncManifest.swift` | `data/api/dto/*.kt` | `DtoDecodingTests` |
| `Net/ApiClient.swift` | `data/api/ApiClient.kt` + `AppSignatureInterceptor.kt` | `ApiClientTests` (~48 + retry-матрица из `SigningTest.kt`) |
| `Net/URLSessionTransport.swift` (+ фабрика клиентов) | `ApiClient.defaultOkHttpClient` + `AppContainer.kt` | `LiveServerSmokeTests` (gated) |
| `Data/Repositories/RaceRepository.swift` | `data/RaceRepository.kt` | `RaceRepositoryTests` (12) |
| `Data/Repositories/TeamRepository.swift` | `data/TeamRepository.kt` | `TeamRepositoryTests` (18) |
| `Data/Repositories/LegendRepository.swift` | `data/LegendRepository.kt` | `LegendRepositoryTests` (29) |
| `Data/Repositories/MemberTagsRepository.swift` | `data/MemberTagsRepository.kt` | `MemberTagsRepositoryTests` (32) |

**Grep-инварианты (расширение правил этапов 1–2):** `import GRDB` — только под `Data/`; `import UIKit|SwiftUI` — нигде под `Core/`, `Model/`, `Data/`, `Net/`; `Net/` без `import GRDB`.

## Technical Details

**Подпись (6 заголовков на каждом запросе).** `X-App-Key-Id` = `Secrets.appKeyId`; `X-App-Sig` = lower-hex HMAC-SHA256 канонической строки (64 симв.); `X-App-Ts` = unix-**секунды** строкой из `nowSeconds()` (читается заново при retry); `X-Install-Id` = `InstallId`; `X-App-Platform` = `"ios"` (Android шлёт `"android"`); `X-App-Version` = `CFBundleShortVersionString`. Каноника — `buildCanonical(method, fullPath, ts, bodyHash)` из этапа 1: `METHOD\nfullPath\nts\nbodyHash` (fullPath = encodedPath + `?query` при наличии, с завершающим слэшем). `bodyHash`: тело POST сериализуется **один раз** в `Data` — эти же байты и хэшируются, и отправляются; GET/пустое тело → `EMPTY_BODY_SHA256`. `Authorization: Bearer` при `tokenProvider() != nil` — **не входит** в канонику.

**403-retry (GET/HEAD only).** После ответа: `403 && метод GET/HEAD && nowSeconds() != usedTs` → закрыть и повторить со свежей подписью, один раз. Работает потому, что шаг `onServerTime` уже перезаякорил `TrustedClock` по `Date` из 403-ответа — новый `ts` попадает в окно ±300 с. POST не ретраится (403 неразличим auth-vs-skew, replay небезопасен).

**`ServerTimeSampler` (порт `ServerTimeInterceptor.kt`).** Чистая функция: `Date`-заголовок (RFC 1123) + `requestElapsedMs`/`responseElapsedMs` → `ServerTimeSample(serverEpochMs, anchorElapsedMs)?`: серверное время относится к **середине RTT** — `anchorElapsedMs = requestElapsedMs + rtt/2` (overflow-safe форма из Kotlin, не `(req+resp)/2`); отсутствующий/битый `Date` → nil (no-op); отрицательный RTT или RTT > лимита (значение лимита взять из Kotlin) → nil; out-of-order ответы разруливает потребитель (`TrustedClock` сам отбрасывает регрессию). `wallNow`/`bootNow`, которые нужны `TrustedClock.onServerTime`, — **не** дело сэмплера: их захватывает вайринг-замыкание фабрики из `SystemClockProviders`. `ApiClient` вызывает `onServerTime` при каждом ответе cloud-клиента, включая 403.

**Result-типы.**

```swift
enum FetchResult<T> {
    case success(data: T, etag: String?)  // 200
    case notModified                      // 304
    case forbidden                        // 403 (после retry)
    case error(code: Int?)                // прочие; nil = URLError или ошибка парсинга
}
enum PostResult<T> {
    case success(T)                       // 200/201
    case badRequest                       // 400
    case unauthorized                     // 401
    case forbidden                        // 403
    case conflict                         // 409
    case rateLimited                      // 429
    case offline                          // URLError (транспорт)
    case error(code: Int?)                // прочие; nil = ошибка парсинга
}
enum RefreshResult: Equatable { case updated, notModified, offline, forbidden, httpError(Int), skipped }
```

Асимметрия из Kotlin сохраняется: `URLError` на GET → `.error(nil)`, на POST → `.offline` (офлайн на гонке — ожидаемое состояние для загрузки).

**Условный GET.** `If-None-Match` = сохранённый ETag **verbatim, с кавычками**; `200` → `success(parse(body), заголовок ETag как есть)`, `304` → `.notModified`. ETag сильный, дельта-синка нет — 200 всегда полный список → replace целиком.

**DTO (`Net/Dto/`).** `Codable`; snake_case через `CodingKeys` точечно (`date_end`, `reg_status`, `start_number`, `paid_people`, `start_time`, `number_in_team`, `check_method`, `checkpoint_id`, `nfc_uid`, `total_cost`, `scoring_count`, `data_source`, `lease_ttl_seconds`, `lease_expires_at`; однословные `id/number/cost/type/description/enc/color/iv/ct/bid` — без маппинга). Незнакомые ключи игнорируются (дефолт `Codable`; `sync.versions` сознательно не маппится). Forward-compat: `total_cost`/`scoring_count` дефолт `0`, `tags` дефолт `[]` (`decodeIfPresent ?? default` в ручном `init(from:)`), `TeamDto.start_number` — optional; `CheckpointDto.cost/description/enc/color` все optional (`enc != nil` — сентинел locked; locked-КП приходит без `cost`/`description`; `color ?? ""`). Ловушки: `start_time`/`finish_time` — **миллисекунды** (`Int64`, `0` = нет), `paid_people: Double`, `order` категории → `sortOrder`, тег-ключ легенды — `checkpoint_id` (в примере API.md устаревший `point`), `EncDto{iv, ct}` — base64-строки.

**Репозитории — общий refresh-поток** (поведенчески точный перенос, это серверный контракт):

1. **pin-guard** (Team/Legend/MemberTags; **не** Race — гонки глобальны): `source == .cloud && isRacePinned(raceId)` или `source == .local && !isRacePinned(raceId)` → `.skipped` **до** сетевого вызова;
2. `(client, originKey)` по `source` (cloud → `apiClient`/`origin`, local → `localApiClient`/`localOrigin`) → `syncMetaStore.getEtag(origin, resource)` → условный GET;
3. на `success`: **повторно проверить pin-guard** (защита от смены источника в полёте — свежие строки не затираются) → `deleteEtag` другого origin для ресурса → `replaceAllForRace` → `upsert` нового ETag (если сервер прислал). **Критично: три раздельные транзакции, порядок «данные → потом ETag»** — краш между ними оставит свежие данные без ETag (следующий refresh получит лишний 200 и самоизлечится); обратный порядок навсегда пришпилит новый ETag к старым данным;
4. `.notModified`/`.forbidden` — прозрачно; `.error(nil)` → `.offline`, `.error(code)` → `.httpError(code)`.

Ключи `sync_meta`: origin = base URL (партиционирование cloud/LAN); resource: `"races"`, `"race/<id>/teams"`, `"race/<id>/legend"`, `"race/<id>/member_tags"`, `"race/<id>/member_tags/synced"`.

**Особенности по репозиториям:**

- **RaceRepository:** без pin-guard, `raceStore.replaceAll` (глобально). `fetchSync(raceId:)` живёт в `ApiClient` (тривиальный GET без ETag — закрывает контракт клиента целиком), потребитель-координатор — этап 9.
- **TeamRepository:** `teamStore.replaceAllForRace(raceId, categories, teams)` (одна транзакция над двумя таблицами — уже готова). Маппинг DTO → `Category` (`order`→`sortOrder`) и `Team` (+`TeamMemberItem`).
- **LegendRepository:** персистит в 3 store — `checkpointStore.replaceAllForRace` (**preserve-reveal** — уже готов), `tagStore.replaceAllForRace`, `legendMetaStore.upsert(LegendMeta(raceId, totalCost, scoringCount))`. Маппинг `CheckpointDto`: `enc != nil` → locked, `color ?? ""`. Плюс **`unlock(raceId:code:) async -> UnlockOutcome`** (офлайн-reveal, сети нет): `bid = LegendCrypto` по коду → `tagStore.getByBid(bid, raceId)` → собрать `encById` из строк checkpoints → чистый `LegendCrypto.unlock` (этап 1) → на `revealed` — `checkpointStore.reveal(id, cost, description)` по каждому КП. Исходы: `revealed`/`identityOnly`/`unknown`/`failed` (`UnlockOutcome` из этапа 1).
- **MemberTagsRepository:** `memberTagStore.replaceAllForRace`. Доп. маркер `sync_meta["race/<id>/member_tags/synced"] = "1"` на **любой** успешный 200 (даже если сервер не прислал ETag) — отличает «пул пуст, но синк был» от «синка не было»; маркер и ETag другого origin чистятся перед заменой. `hasBeenSynced()` / `observeHasBeenSynced()` поверх `SyncMetaStore.observeEtagsExist` (уже готов).

**Прод-транспорт и фабрика.** `URLSessionTransport`: `URLSessionConfiguration.ephemeral`, `urlCache = nil`, `requestCachePolicy = .reloadIgnoringLocalCacheData` (заголовок `Date` всегда живой). Фабрика (по образцу `AppContainer.kt`): cloud-клиент — `Secrets.apiBaseURL`, таймауты 10 с, `onServerTime` → `TrustedClock`; LAN-клиент — `Secrets.localAPIBaseURL`, таймауты 3 с (быстрый офлайн-фейл вне Wi-Fi), `onServerTime = nil`. Вайринг в приложение — этап 4.

**Smoke.** `LiveServerSmokeTests` — `@Suite(.enabled(if: ProcessInfo.processInfo.environment["LIVE_API_SMOKE"] != nil))`: подписанный `GET /app/races/` через настоящий `URLSessionTransport` и реальные `Secrets` → ожидаем `.success` (в т.ч. проверка, что подпись принята сервером — 200, не 403). Запуск руками: `LIVE_API_SMOKE=1` в окружении + `-only-testing:kolco24Tests/LiveServerSmokeTests`.

## Implementation Steps

### Task 1: SyncSource + ServerTimeSampler

**Files:**
- Create: `kolco24/Core/Sync/SyncSource.swift`
- Create: `kolco24/Core/Time/ServerTimeSampler.swift`
- Create: `kolco24Tests/Core/ServerTimeSamplerTests.swift`

- [x] `enum SyncSource { case cloud, local }` (порт `data/SyncSource.kt`; чистый тип — нужен репозиториям сейчас и координатору этапа 9)
- [x] `ServerTimeSampler` ← `ServerTimeInterceptor.kt`: чистая функция разбора RFC 1123 `Date`-заголовка + RTT-правила (midpoint `requestElapsedMs + rtt/2`; лимит RTT — значение из Kotlin; отрицательный/сверхлимитный → nil); `ServerTimeSample(serverEpochMs, anchorElapsedMs)` — `wallNow`/`bootNow` захватывает вайринг-замыкание фабрики (задача 8), не сэмплер
- [x] `ServerTimeSamplerTests` ← `ServerTimeInterceptorTest.kt` (~6–7 из 9 кейсов принадлежат чистому сэмплеру): Date+RTT midpoint, отсутствующий/битый Date → nil, RTT at-max принят / over-max и отрицательный отброшены. Остальные кейсы Kotlin перенацеливаются: cache-gate — беспредметен при ephemeral-транспорте без кэша (зафиксировано конфигом в задаче 8), out-of-order — покрыт регрессией в существующих `TrustedClock`-тестах, «null bootCount forwarded» — вайринг фабрики (задача 8)
- [x] прогнать тесты — must pass before task 2

### Task 2: Result-типы + DTO

**Files:**
- Create: `kolco24/Net/ApiResults.swift`
- Create: `kolco24/Net/Dto/RacesResponse.swift`, `TeamsResponse.swift`, `LegendResponse.swift`, `MemberTagsResponse.swift`, `SyncManifest.swift`
- Create: `kolco24Tests/Net/DtoDecodingTests.swift`

- [x] `FetchResult<T>`/`PostResult<T>` по Technical Details (enum'ы, ошибки не бросаются)
- [x] 5 DTO-файлов ← `data/api/dto/*.kt`: Codable, CodingKeys точечно, forward-compat-дефолты через `decodeIfPresent ?? default`, все ловушки из Technical Details закомментированы у полей (ms-время, `paid_people: Double`, `checkpoint_id`, base64 `iv`/`ct`)
- [x] `DtoDecodingTests`: JSON-образцы **вшиваются в тест-файл** (источник — `kolco24_app_v2/docs/design/API.md`, в iOS-репо этого файла нет; тест самодостаточен): полный + минимальный ответ, locked-КП без `cost`/`description`, отсутствующие `total_cost`/`scoring_count`/`tags` → дефолты, незнакомые ключи (в т.ч. `sync.versions`) игнорируются, `start_number: null`
- [x] прогнать тесты — must pass before task 3

### Task 3: ApiClient — пайплайн (подпись, серверное время, 403-retry, post)

**Files:**
- Create: `kolco24/Net/ApiClient.swift`
- Create: `kolco24Tests/Net/FakeTransport.swift` (очередь ответов + журнал `URLRequest` — общий для задач 3–8)
- Create: `kolco24Tests/Net/ApiClientTests.swift` (часть 1: пайплайн)

- [x] `struct ApiClient` с полями-замыканиями по Solution Overview (**`nowSeconds`/`onServerTime` — `async`, await inline**: retry-решение читает `nowSeconds()` строго после завершения `onServerTime` — иначе самолечение 403 флаки); приватный пайплайн `get`/`post`: построение `URLRequest` → 6 заголовков подписи (`buildCanonical`/`sign` этапа 1, `X-App-Platform: ios`) → транспорт с замером RTT по `elapsedNowMs` → `ServerTimeSampler` → `await onServerTime?` → 403-retry-once для GET/HEAD при сменившемся `ts`
- [x] generic `post`: тело сериализуется один раз в `Data`, эти байты хэшируются и отправляются; маппинг статусов в `PostResult` (400/401/403/409/429, `URLError` → `.offline`, парс-ошибка → `.error(nil)`); POST никогда не ретраится
- [x] `Authorization: Bearer` при `tokenProvider() != nil`, не входит в канонику
- [x] тесты (зеркала `ApiClientTest.kt` + retry-матрица из `SigningTest.kt`): все 6 заголовков присутствуют, подпись сверяется пересчётом над перехваченным запросом, empty-body hash у GET, POST-тело хэшируется байт-в-байт, bearer добавлен/опущен; retry-матрица — GET ретраится один раз при сменившемся ts / не ретраится при том же ts / POST никогда / нет retry на 200; `onServerTime` вызван (в т.ч. на 403), у клиента с `onServerTime = nil` — нет
- [x] прогнать тесты — must pass before task 4

### Task 4: ApiClient — эндпоинты и условные GET

**Files:**
- Modify: `kolco24/Net/ApiClient.swift`
- Modify: `kolco24Tests/Net/ApiClientTests.swift` (часть 2: эндпоинты)

- [x] `conditionalGet` поверх пайплайна: `If-None-Match` verbatim, `200` → `.success(data:etag:)`, `304` → `.notModified`, `403` → `.forbidden`, прочие → `.error(code)`, `URLError` → `.error(nil)`, парс-ошибка → `.error(nil)`
- [x] эндпоинты: `fetchRaces(etag:)`, `fetchTeams(raceId:etag:)`, `fetchLegend(raceId:etag:)`, `fetchMemberTags(raceId:etag:)`, `fetchSync(raceId:)` (без ETag) — пути с завершающим слэшем от `baseURL` без хвостового `/`
- [x] тесты (остаток ~48 зеркал `ApiClientTest.kt`): точный путь + завершающий слэш на каждом эндпоинте, `If-None-Match` отправлен/опущен, разбор 200 (данные+etag)/304/403/500, обрыв соединения (транспорт бросает `URLError`), битый JSON → `.error(nil)`, парсер не вызывается на не-200
- [x] прогнать тесты — must pass before task 5

### Task 5: RaceRepository (эталон refresh-потока)

**Files:**
- Create: `kolco24/Data/Repositories/RaceRepository.swift` (+ `RefreshResult` здесь или соседним файлом)
- Create: `kolco24Tests/Data/Repositories/RaceRepositoryTests.swift`

- [ ] `RefreshResult` enum; `RaceRepository` (без pin-guard): ETag из `SyncMetaStore` → `fetchRaces` → deleteEtag другого origin → `raceStore.replaceAll` → upsert ETag; маппинг `RaceDto` → `Model/Race`; `source: SyncSource = .cloud` выбирает клиента и origin
- [ ] `RaceRepositoryTests` ← `RaceRepositoryTest.kt` (12 кейсов) над in-memory GRDB: success заменяет и сохраняет ETag, 304 не трогает данные, второй refresh шлёт сохранённый ETag, offline/forbidden/httpError, ответ без ETag — данные записаны и ETag не создан, **данные записаны раньше ETag** (проверка порядком операций фейк-store'а или крашем между шагами), local-source пишет в свой origin, кросс-origin-инвалидация
- [ ] прогнать тесты — must pass before task 6

### Task 6: TeamRepository + MemberTagsRepository (pin-guard + synced-маркер)

**Files:**
- Create: `kolco24/Data/Repositories/TeamRepository.swift`, `MemberTagsRepository.swift`
- Create: `kolco24Tests/Data/Repositories/TeamRepositoryTests.swift`, `MemberTagsRepositoryTests.swift`

- [ ] общий refresh-поток с pin-guard (до вызова **и** повторно после 200) через `isRacePinned`-seam; маппинги DTO → `Team`/`TeamMemberItem`/`Category` (`order`→`sortOrder`, ms-время) и `MemberTag`
- [ ] `MemberTagsRepository`: synced-маркер на любой 200, чистка маркера+ETag другого origin перед заменой, `hasBeenSynced()`/`observeHasBeenSynced()`
- [ ] `TeamRepositoryTests` ← `TeamRepositoryTest.kt` (18): всё из задачи 5 + полная pin-guard-матрица (pinned-cloud → skipped, unpinned-local → skipped, pin появился в полёте → после 200 не персистит, pin исчез в полёте, unpinned-cloud работает), изоляция по raceId
- [ ] `MemberTagsRepositoryTests` ← `MemberTagsRepositoryTest.kt` (32): + synced-маркер во всех вариантах (200 без ETag, 304, forbidden, кросс-origin), `hasBeenSynced`/`observeHasBeenSynced`
- [ ] прогнать тесты — must pass before task 7

### Task 7: LegendRepository (3 store + unlock)

**Files:**
- Create: `kolco24/Data/Repositories/LegendRepository.swift`
- Create: `kolco24Tests/Data/Repositories/LegendRepositoryTests.swift`

- [ ] refresh с pin-guard: `checkpointStore.replaceAllForRace` (preserve-reveal) + `tagStore.replaceAllForRace` + `legendMetaStore.upsert`; маппинг `CheckpointDto` (`enc != nil` → locked, `color ?? ""`, optional cost/description)
- [ ] `unlock(raceId:code:) async -> UnlockOutcome`: bid → `tagStore.getByBid` → `encById` из строк checkpoints → `LegendCrypto.unlock` → `checkpointStore.reveal` на `revealed`
- [ ] `LegendRepositoryTests` ← `LegendRepositoryTest.kt` (29): refresh-набор + маппинг locked/color/tags, `total_cost`/`scoring_count` персист и дефолты, reveal переживает resync (поверх preserve-reveal); unlock-матрица — reveal+persist, неизвестный bid → unknown, открытый КП → identityOnly, частичный конверт, испорченный шифротекст → failed (KAT-векторы `LegendCryptoTests` этапа 1 переиспользуются)
- [ ] прогнать тесты — must pass before task 8

### Task 8: URLSessionTransport + фабрика клиентов + live smoke

**Files:**
- Create: `kolco24/Net/URLSessionTransport.swift`
- Create: `kolco24Tests/Net/LiveServerSmokeTests.swift`

- [ ] `URLSessionTransport`: ephemeral-конфигурация, без кэша, настраиваемые таймауты; фабрика клиентов (по `AppContainer.kt`): cloud (`Secrets.apiBaseURL`, 10 с, `onServerTime` → `TrustedClock.makeDefault()`), LAN (`Secrets.localAPIBaseURL`, 3 с, `onServerTime = nil`); `X-App-Version` из бандла; trailing `/` у baseURL срезается
- [ ] `LiveServerSmokeTests` (`.enabled(if:` env `LIVE_API_SMOKE`)): подписанный `GET /app/races/` через реальный транспорт и `Secrets` → `.success` (сервер принял подпись)
- [ ] прогнать полный локальный сьют (smoke скипается без env); затем один запуск с `LIVE_API_SMOKE=1 -only-testing:kolco24Tests/LiveServerSmokeTests` → 200
- [ ] прогнать тесты — must pass before task 9

### Task 9: Verify acceptance criteria

- [ ] полный `xcodebuild test` зелёный (все кейсы этапов 0–2 + ~150 новых), `** TEST SUCCEEDED **`
- [ ] сверка покрытия: `ApiClientTest` 48/48, `ServerTimeInterceptorTest` 9/9, retry-матрица `SigningTest` закрыта, `RaceRepositoryTest` 12/12, `TeamRepositoryTest` 18/18, `LegendRepositoryTest` 29/29, `MemberTagsRepositoryTest` 32/32 — header-комментарии «Зеркало …», бонусы помечены
- [ ] grep-инварианты: `import GRDB` только под `Data/`; `import UIKit|SwiftUI` отсутствует в `Core/`, `Model/`, `Data/`, `Net/`; `Net/` без GRDB
- [ ] UI не тронут: ни один из 8 корневых UI-файлов не в диффе; `project.pbxproj` не трогали
- [ ] smoke против живого сервера пройден (200, задача 8)
- [ ] инварианты потока перечитаны по чек-листу: данные-раньше-ETag, кросс-origin-инвалидация, повторный pin-guard после 200, POST-не-ретраится, LAN без `onServerTime`

### Task 10: [Final] Документация

**Files:**
- Modify: `docs/plans/android-port.md`
- Modify: `CLAUDE.md`

- [ ] в `android-port.md` пометить этап 3 ✅ со ссылкой на этот план (по образцу этапов 0–2); поправить устаревшую ссылку `docs/API.md` → `docs/design/API.md` в «Принципах»
- [ ] в `CLAUDE.md` описать `Net/` (пайплайн вместо интерсепторов, транспорт-seam, result-типы) и `Data/Repositories/` (refresh-поток, «данные → ETag», pin-guard-seam, unlock), grep-инварианты, smoke-запуск
- [ ] переместить этот план в `docs/plans/completed/` (поправить ссылку в шапке на `../android-port.md`)

## Post-Completion

**Manual verification:**
- живые данные в UI (легенда/команды с сервера на экране) — этап 4;
- LAN-режим против реального локального сервера — этап 9 (сейчас проверяется только партиционирование origin'ов в тестах);
- generic `post`-пайплайн против живого сервера — этап 6 (эндпоинты загрузки).

**External system updates:**
- нет: серверный контракт не меняется, Android-репо не затрагивается.
