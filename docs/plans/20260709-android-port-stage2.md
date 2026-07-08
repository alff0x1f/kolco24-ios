# Этап 2 портирования: данные — БД (GRDB) и хранилища

Детализация этапа 2 из [android-port.md](android-port.md). Этапы 0 (инфраструктура) и 1 (чистая логика) выполнены.

## Overview

Перенести слой данных Android-приложения (`/Users/alff0x1f/src/kolco24_app_v2`, Room v5, файл `kolco24.db`) на GRDB:

- схема: все 13 таблиц одной миграцией `"v1"` = снимок финальной схемы Room v5 (историю миграций 1→5 не повторять — iOS-база рождается с нуля);
- слой запросов: 12 store-структур, по одной на Android-DAO, включая всю upload-дренажную логику (marks/track/judge);
- key-value: `InstallId` + `ClockAnchorStore` (UserDefaults, через `load`/`save`-seam) и подключение последнего к `TrustedClock` фабрикой `makeDefault()`;
- тесты: зеркала 23 инструментальных DAO-тестов + 5 JVM-тестов конвертеров/сторов, всё поверх in-memory GRDB (бонус платформы: на Android это эмуляторные тесты, у нас — обычные unit'ы).

После этапа: этап 3 (сеть) получает готовые инъецируемые store'ы для sync-репозиториев, этап 4 подписывается на observation'ы. UI не меняется.

## Context (from discovery)

- **Источник правды по DDL:** `app/schemas/ru.kolco24.kolco24.data.db.AppDatabase/5.json` (Room `exportSchema`); сами сущности/DAO — `app/src/main/java/ru/kolco24/kolco24/data/db/`.
- **13 таблиц:** races, categories, teams, selected_team (одна строка `id=1`), checkpoints, tags, member_tags, member_chip_bindings, marks, legend_meta, track_points, judge_scans, sync_meta. **FK нет нигде** — связи по id в запросах; не добавлять (изменит поведение `replaceAllForRace`).
- **Композитные PK:** `tags(raceId,bid)`, `member_tags(raceId,nfcUid)`, `member_chip_bindings(teamId,numberInTeam)`, `sync_meta(origin,resource)`. **Клиентские TEXT-UUID PK:** marks, track_points, judge_scans (идемпотентный merge двух серверов).
- **JSON-колонки (TEXT + конвертер):** `teams.members` (`List<TeamMemberItem>`, ключ `number_in_team`), `marks.present` (`[Int]`, non-null), `marks.presentDetails` (`[MarkMemberSnapshot]?`, nullable — NULL у легаси-строк). Kotlin-конвертеры: `ignoreUnknownKeys`, битый JSON → fallback (пустой список / nil) + лог, не краш.
- **Room-дефолты** (`= false` и т.п.) — котлиновские, НЕ SQL `DEFAULT`. Важно: в `createSql` из `5.json` **нет ни одного `DEFAULT`** — `DEFAULT 0` встречается только в промежуточных `ALTER TABLE`-миграциях в `AppDatabase.kt`, и Room не сворачивает их обратно в экспортированную схему. Портируем `5.json` дословно, без SQL-дефолтов; дефолты — на стороне Swift-инициализаторов.
- **Готово из этапа 1:** `Model/Checkpoint|Mark|MemberChipBinding` (+`MarkMemberSnapshot`) — им нужны только конформансы; `TrustedClock` ждёт `persist`/`persisted` (сейчас — только фейки в тестах).
- **Синхронизированная группа:** новые подпапки `kolco24/Data/`, `kolco24Tests/Data/` попадают в таргеты автоматически, `project.pbxproj` не трогаем.
- **Android-тесты для зеркалирования:** androidTest (in-memory Room): `MarkDaoTest` (12), `CheckpointDaoTest` (4), `JudgeScanDaoTest` (7); JVM: `IntListConverterTest`, `MarkMemberSnapshotListConverterTest`, `TeamMembersConverterTest`, `InstallIdTest`, `ClockAnchorStoreTest`. `MigrationTest` не зеркалируется (мигрировать нечего) — вместо него schema-snapshot-тест.
- **Дыра Android, которую закрываем бонусом:** 9 из 12 DAO (все кроме Mark/Checkpoint/JudgeScan) реальным SQL не тестируются — их репо-тесты ходят в фейки. In-memory GRDB бесплатен → базовые тесты каждому store.

## Development Approach

- **testing approach**: порт-TDD — Android-тесты каждого модуля переносятся вместе с ним в той же задаче (сценарии и имена кейсов 1:1); бонус-тесты сверх Kotlin помечаются в тест-файле комментарием;
- complete each task fully before moving to the next;
- make small, focused changes (коммит на задачу или пару мелких);
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task;
- **CRITICAL: all tests must pass before starting next task**;
- **CRITICAL: update this plan file when scope changes during implementation**.

## Testing Strategy

- **unit tests**: Swift Testing в `kolco24Tests/Data/…` поверх `AppDatabase.makeInMemory()` (GRDB `DatabaseQueue()`); key-value-сторы — через `load`/`save`-seam с in-memory-словарём, как их Kotlin-зеркала.
- **schema-snapshot**: один тест сверяет инвентарь таблиц/колонок/индексов/PK (`sqlite_master` + `PRAGMA table_info`/`index_list`) с ожидаемым, транскрибированным из `5.json`.
- **e2e**: нет. Живая проверка (реальные данные с сервера в БД) — этап 3.
- Прогон: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'` (нужен `Config/Secrets.xcconfig`; при флаки-имени — `id=<UDID>` из `xcrun simctl list devices available`).

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview

**Архитектура — вариант A (store-структуры), решения брейншторма:**

1. Имена таблиц/колонок **1:1 с Room v5** (camelCase-колонки как в Room DDL) — SQL из DAO переносится дословно, сверка с Android тривиальна.
2. `Data/AppDatabase.swift` — держит `any DatabaseWriter` + `DatabaseMigrator` (одна миграция `"v1"`); `makeShared()` = `DatabasePool` (WAL), файл `kolco24.db` в Application Support; `makeInMemory()` = `DatabaseQueue` для тестов.
3. `Data/Records/*.swift` — GRDB-конформансы (`FetchableRecord`/`PersistableRecord`) **extension'ами** к `Model/`-типам: `Model/` остаётся без `import GRDB` (grep-инвариант, продолжение правила этапа 1).
4. `Data/Stores/*.swift` — 12 store-структур (`struct`, не protocol: тестам и репозиториям этапа 3 хватает настоящих store'ов над in-memory базой, фейки не нужны). Kotlin `suspend` → `async throws` через `read`/`write`; Kotlin `Flow` → `ValueObservation.tracking{…}.values(in:)` (реактивность сразу — этап 4 только подпишется). Дедуп равных значений у `ValueObservation` из коробки (Room-Flow переизлучает чаще — консюмерам безразлично).
5. SQL сложных запросов переносится **дословно строкой** (сортировка `startNumber`, `COALESCE(trustedTakenAt, takenAt)`, CASE-агрегаты) — цель сверяемость, не красота DSL.
6. Key-value — только с ближним потребителем: `InstallId` (заголовок `X-Install-Id` этапа 3, `judge_scans.sourceInstallId`) и `ClockAnchorStore` (уже ждёт `TrustedClock`). `ThemePreference`/`TrackProfilePreference` → этапы 8–9, `AdminTokenStore` (Keychain) → этап 10, `RaceLeaseStore` → этап 9 — **не делать**.
7. Композицию в приложение (аналог `AppContainer`) **не делать** — UI-файлы не трогаем, контейнер появится на этапах 3–4. Этап 2 сдаёт детали + фабрики.

**Раскладка:**

| iOS-файл | Kotlin-источник | Тесты |
|---|---|---|
| `Model/Race|Category|Team|SelectedTeam|Tag|MemberTag|LegendMeta|TrackPoint|JudgeScan|SyncMeta.swift` | `data/db/*Entity.kt` | через store'ы |
| `Data/AppDatabase.swift` | `data/db/AppDatabase.kt` + `schemas/5.json` | `AppDatabaseSchemaTests` |
| `Data/Records/*+GRDB.swift` (13 шт.) | Room-аннотации + 3 конвертера | `IntListCodecTests`, `MarkMemberSnapshotListCodecTests`, `TeamMembersCodecTests` |
| `Data/Stores/RaceStore|TeamStore|SelectedTeamStore|TagStore|MemberTagStore|MemberChipBindingStore|SyncMetaStore|LegendMetaStore.swift` | одноимённые `*Dao.kt` | базовые (бонус, в Android SQL не покрыт) |
| `Data/Stores/CheckpointStore.swift` | `CheckpointDao.kt` | `CheckpointStoreTests` ← `CheckpointDaoTest` (4) |
| `Data/Stores/MarkStore.swift` | `MarkDao.kt` | `MarkStoreTests` ← `MarkDaoTest` (12) + бонус |
| `Data/Stores/TrackStore.swift`, `JudgeScanStore.swift` | `TrackDao.kt`, `JudgeScanDao.kt` | `JudgeScanStoreTests` ← `JudgeScanDaoTest` (7); `TrackStoreTests` (бонус) |
| `Core/Stores/InstallId.swift` | `data/InstallId.kt` | `InstallIdTests` ← `InstallIdTest` |
| `Core/Time/ClockAnchorStore.swift` | `data/time/ClockAnchorStore.kt` | `ClockAnchorStoreTests` ← `ClockAnchorStoreTest` |

## Technical Details

**Схема (`"v1"`).** Дословно из `5.json`: типы INTEGER/TEXT/REAL, Bool = INTEGER 0/1 (GRDB конвертирует нативно), `Float` (locAccuracy, locVerticalAccuracy, track accuracy/verticalAccuracyMeters) = REAL. Индексы: `teams(raceId)`, `checkpoints(raceId)`, `tags(raceId)`+`tags(checkpointId)`, `member_tags(raceId)`, `member_chip_bindings(nfcUid)`, `marks(raceId|teamId|checkpointId)`, `track_points(raceId|teamId)`, `judge_scans(raceId)` — все non-unique. Без SQL-`DEFAULT` (в `createSql` из `5.json` их нет — см. Context).

**Record-конформансы.** `Model/`-структуры не Codable — конформанс вручную: `init(row: Row)` + `encode(to container: inout PersistenceContainer)` в extension'ах `Data/Records/`. JSON-колонки кодируются здесь же (аналог Room TypeConverter): `JSONEncoder` с `.sortedKeys` (стабильный вывод для тестов), `JSONDecoder` — незнакомые ключи игнорируются по умолчанию; ошибка декодирования → fallback (`present` → `[]`, `presentDetails` → `nil`, `members` → `[]`) + лог, не краш. `TeamMemberItem` кодируется с ключом `number_in_team` (CodingKeys).

**Конфликт-семантика записи** (соответствие Room):
- `@Insert(REPLACE)` (races, teams, categories, checkpoints, tags, member_tags) → `insert(db, onConflict: .replace)`;
- `@Upsert` (selected_team, sync_meta, legend_meta, member_chip_bindings) → `upsert(db)`;
- `@Insert(IGNORE)` (track_points — идемпотентность по UUID) и `@Insert` write-once (judge_scans) → `insert(db, onConflict: .ignore)` / `insert(db)`.

**Инвентарь store'ов** (методы = имена методов DAO; F = Flow→observation, s = suspend→async):

- **RaceStore:** F `observeRaces` (`ORDER BY date DESC, id DESC`), s `insertAll`, `deleteAll`, `replaceAll` (транзакция wipe+insert).
- **TeamStore:** F `observeTeamsForRace` — дословный SQL `ORDER BY (startNumber IS NULL OR startNumber = ''), CAST(NULLIF(startNumber,'') AS INTEGER), startNumber, id`; F `observeCategoriesForRace` (`sortOrder, id`), F `observeTeamById`; s `insertTeams`/`insertCategories`, `deleteTeamsForRace`/`deleteCategoriesForRace`, `replaceAllForRace(raceId, categories, teams)` — одна транзакция над **двумя** таблицами.
- **SelectedTeamStore:** F `observe` (`WHERE id = 1`), s `upsert`, `clear`.
- **TagStore:** F `observeTagsForRace` (`checkpointId, bid`), s `getByBid(bid, raceId)`, `insertTags`, `deleteTagsForRace`, `replaceAllForRace`.
- **MemberTagStore:** F `observeForRace` (`number, nfcUid`), s `findByUid(raceId, nfcUid)`, `insertAll`, `deleteForRace`, `replaceAllForRace`.
- **MemberChipBindingStore:** F `observeForTeam` (`numberInTeam`), s `findByUid`, `upsert`, `deleteSlot(teamId, numberInTeam)`, `deleteByUid`, `reassign(binding)` — транзакция deleteByUid→upsert (атомарный перенос браслета).
- **SyncMetaStore:** s `getEtag(origin, resource)`, F `observeEtagsExist(origin, resource1, resource2)` (`SELECT EXISTS(… resource IN (…))`), s `upsert`, `deleteEtag`.
- **LegendMetaStore:** F `observeForRace`, s `upsert`.
- **CheckpointStore:** F `observeCheckpointsForRace` (`number, id`), s `insertCheckpoints`, `deleteCheckpointsForRace`, `revealedForRace` (`WHERE cost IS NOT NULL`), `reveal(id, cost, description)` (`UPDATE … SET cost, description, locked = 0`), `getCheckpointsForRace`, `replaceAllForRace` — **preserve-reveal**: в одной транзакции снапшот revealed-строк → wipe+insert серверных → re-apply plaintext (`reveal`) к строкам, пришедшим снова locked, чей id был раскрыт.
- **TrackStore:** F `observeForTeam` (`ORDER BY COALESCE(trustedMs, wallMs), COALESCE(bootCount,-1), elapsedRealtimeAt, id`), F `countForTeam`, F `uploadCounts(teamId, raceId)` — CASE-агрегат в `UploadCounts(total, local, cloud)`; s `insertAll` (IGNORE), `deleteForTeam`, `unuploadedLocal|Cloud(raceId, teamId, limit)` (сортировка по времени), `markUploadedLocal|Cloud(ids)`, `pendingUploadScopes()` (`SELECT DISTINCT raceId, teamId … WHERE uploadedLocal = 0 OR uploadedCloud = 0` → `TrackScope`).
- **JudgeScanStore:** s `insert` (write-once), `unuploadedLocal|Cloud(raceId, limit)` (`ORDER BY COALESCE(trustedTakenAt, takenAt), id`), `markUploadedLocal|Cloud(ids)`, `pendingUploadRaces()`; F `uploadCounts(raceId)`.
- **MarkStore** (богатейший): F `observeForTeam` (`ORDER BY COALESCE(trustedTakenAt, takenAt) DESC`), s `getById`, `allIds` (sweep осиротевших фото-папок), `upsert`;
  - `addMember(id, numberInTeam, nfcUid, number, code, now, expectedCount)` — транзакционный read-modify-write: set-семантика по `numberInTeam` в `present` **и** `presentDetails`, пересчёт `complete = present.count >= expectedCount`, bump `updatedAt = now`, сброс `uploadedLocal = uploadedCloud = 0`;
  - `attachLocation(…)` — column-scoped UPDATE 7 `loc*`-колонок + сброс `uploaded*`;
  - `attachPhotos(id, newPaths, now)` — транзакция: merge JSON-списка путей в `photoPath`, `updatedAt = now`, сброс `photosUploaded*`;
  - version-guarded апдейты: `markUploadedLocal|CloudIfUnchanged(id, updatedAt)` (guard `WHERE updatedAt = ?`), `…IfUnchangedAndNoLocation` (+ `AND locLat IS NULL`), `setPhotosUploadedLocal|CloudIfUnchanged`;
  - F `uploadCounts(teamId, raceId)` — фото-строка uploaded только если metadata **И** frames: `SUM(CASE WHEN uploadedLocal AND (photoPath IS NULL OR photosUploadedLocal) THEN 1 ELSE 0 END)`; F `uploadCountsMetadata` (только metadata); F `photoFrameRows` (`WHERE photoPath IS NOT NULL` → `PhotoFrameRow`);
  - s `unuploadedLocal|Cloud(raceId, teamId, limit)`, `framePendingLocal|Cloud` (`uploadedX = 1 AND photosUploadedX = 0 AND photoPath IS NOT NULL`), `markUploadedLocal|Cloud(ids)`, `pendingUploadScopes()` (расширенное условие: metadata-pending ИЛИ frame-pending).

Вспомогательные типы DAO — `UploadCounts(total, local, cloud)`, `TrackScope(raceId, teamId)`, `PhotoFrameRow` — общие для Mark/Track/JudgeScan store'ов, живут в отдельном `Data/Stores/UploadTypes.swift`.

**Key-value-сторы.** Идиома Android (и уже `TrustedClock`): чистое ядро + инъекция `load`/`save`-замыканий, тонкий адаптер поверх `UserDefaults.standard` (**без** отдельных suite: Android разносил prefs-файлы ради backup-правил, у iOS такой механики нет; риск восстановления устаревшего якоря из бэкапа `TrustedClock` ловит сам регрессией монотонных часов).
- `InstallId`: get-or-create UUID, ключ `install_id`.
- `ClockAnchorStore`: ключ `anchor`, delimited-формат `"serverEpochMs|anchorElapsedMs|capturedWallMs|bootCount?"` **1:1 из Kotlin** (атомарная одноключевая запись; формат уже покрыт тестами — готовая спецификация, Codable-plist не даёт выигрыша). Парсер/форматтер — чистые функции. **Ловушка порта:** при `bootCount == nil` строка кончается на `|` — Kotlin `split('|')` сохраняет хвостовой пустой сегмент (4 части), Swift `split(separator:)` по умолчанию его отбрасывает; парсить через `components(separatedBy: "|")` и требовать ровно 4 компоненты.
- `TrustedClock.makeDefault()` — фабрика: системные провайдеры из `SystemClockProviders` + `persist`/`persisted` из `ClockAnchorStore`.

## Implementation Steps

### Task 1: Доменные типы (Model/, +10 структур)

**Files:**
- Create: `kolco24/Model/Race.swift`, `Category.swift`, `Team.swift` (+ вложенный `TeamMemberItem`), `SelectedTeam.swift`, `Tag.swift`, `MemberTag.swift`, `LegendMeta.swift`, `TrackPoint.swift`, `JudgeScan.swift`, `SyncMeta.swift`

- [x] структуры по образцу этапа 1 (`let`-поля, camelCase, опционалы как в Kotlin, `Equatable`, без суффикса `Entity`, дефолты котлиновских полей — в инициализаторах); `Long`→`Int64`, `Float`→`Float`, `Double`→`Double`
- [x] `Category.sortOrder` (серверное `order` уже переименовано в Android — сохранить), `SelectedTeam.id = 1` по умолчанию, `JudgeScan.elapsedRealtimeAt` non-null (в отличие от `Mark`)
- [x] doc-комментарии в стиле существующих `Model/`-файлов (зеркало какой сущности, назначение)
- [x] сборка проходит; типы без логики — покрываются store-тестами задач 4–7
- [x] прогнать тесты — must pass before task 2

### Task 2: AppDatabase + схема v1 + snapshot-тест

**Files:**
- Create: `kolco24/Data/AppDatabase.swift`
- Create: `kolco24Tests/Data/AppDatabaseSchemaTests.swift`

- [x] `struct AppDatabase`: `let writer: any DatabaseWriter`, `init` прогоняет `DatabaseMigrator` с единственной миграцией `"v1"` — все 13 таблиц дословно из `schemas/5.json` (типы, nullability, PK — включая 4 композитных, все индексы; **без** SQL-`DEFAULT` — в `createSql` их нет)
- [x] `makeShared()`: `DatabasePool` + WAL, `kolco24.db` в Application Support (создать каталог при необходимости); `makeInMemory()`: `DatabaseQueue()`
- [x] `AppDatabaseSchemaTests`: миграция отрабатывает на пустой базе; инвентарь таблиц/колонок (имя, тип, notnull, dflt_value, pk) и индексов совпадает с транскрипцией `5.json` (замена Android `MigrationTest`)
- [x] прогнать тесты — must pass before task 3

### Task 3: Record-конформансы + JSON-кодеки

**Files:**
- Create: `kolco24/Data/Records/` — 13 файлов `<Тип>+GRDB.swift` (Checkpoint, Mark, MemberChipBinding — конформансы существующим типам этапа 1; остальные 10 — новым)
- Create: `kolco24Tests/Data/IntListCodecTests.swift`, `MarkMemberSnapshotListCodecTests.swift`, `TeamMembersCodecTests.swift`

- [x] extension'ы `FetchableRecord`/`PersistableRecord` (`init(row:)` + `encode(to:)` вручную), `databaseTableName` = Room-имя; JSON-колонки (`teams.members`, `marks.present`, `marks.presentDetails`) кодируются внутри конформансов (`.sortedKeys`; decode-fallback `[]`/`nil` + лог)
- [x] `TeamMemberItem` — CodingKeys с `number_in_team`
- [x] grep-инвариант: `import GRDB` только под `Data/`, в `Model/` не появился
- [x] тесты-зеркала 3 Kotlin-конвертер-тестов: round-trip списков, пустой список, NULL ↔ nil (`presentDetails`), битый JSON → fallback без краша, незнакомые ключи игнорируются
- [x] прогнать тесты — must pass before task 4

### Task 4: Простые store'ы (8 шт.) + базовые тесты

**Files:**
- Create: `kolco24/Data/Stores/RaceStore.swift`, `TeamStore.swift`, `SelectedTeamStore.swift`, `TagStore.swift`, `MemberTagStore.swift`, `MemberChipBindingStore.swift`, `SyncMetaStore.swift`, `LegendMetaStore.swift`
- Create: `kolco24Tests/Data/SimpleStoresTests.swift` (или по файлу на store — по вкусу при реализации)

- [ ] 8 store-структур, методы 1:1 по инвентарю из Technical Details; observation'ы через `ValueObservation…values(in:)`, транзакции (`replaceAll*`, `reassign`) — один `write`
- [ ] сортировка команд по `startNumber` — дословный SQL из `TeamDao.kt`
- [ ] базовые тесты (бонус, в Android этот SQL не покрыт): скоупинг по raceId, сортировки (в т.ч. `startNumber` с NULL/''/числами), upsert-семантика, `replaceAllForRace` над двумя таблицами, `reassign` атомарен, `observeEtagsExist`
- [ ] прогнать тесты — must pass before task 5

### Task 5: CheckpointStore (preserve-reveal)

**Files:**
- Create: `kolco24/Data/Stores/CheckpointStore.swift`
- Create: `kolco24Tests/Data/CheckpointStoreTests.swift`

- [ ] методы по инвентарю; `replaceAllForRace` — снапшот revealed → wipe+insert → re-apply plaintext, всё в одной транзакции
- [ ] `CheckpointStoreTests` ← `CheckpointDaoTest.kt` (4 кейса): reveal-then-resync сохраняет контент; resync не раскрывает нераскрытое; открытая строка перезаписывается; выпавший КП удаляется
- [ ] прогнать тесты — must pass before task 6

### Task 6: MarkStore (ядро слоя данных)

**Files:**
- Create: `kolco24/Data/Stores/MarkStore.swift`
- Create: `kolco24/Data/Stores/UploadTypes.swift` (`UploadCounts`, `TrackScope`, `PhotoFrameRow` — общие для Mark/Track/JudgeScan)
- Create: `kolco24Tests/Data/MarkStoreTests.swift`

- [ ] полный инвентарь: `addMember`, `attachLocation`, `attachPhotos`, version-guarded семейство `…IfUnchanged`, CASE-агрегаты `uploadCounts`/`uploadCountsMetadata`, `photoFrameRows`, дренаж `unuploaded*`/`framePending*`, `pendingUploadScopes`
- [ ] `MarkStoreTests` ← `MarkDaoTest.kt` (12 кейсов): `unuploaded*` включают фото-отметки; `uploadCounts` (фото-строка только при metadata+frames); `uploadCountsMetadata` игнорирует frames; `photoFrameRows`; `pendingUploadScopes` (вкл. photo-only и frame-only расширение); `framePending*`-фильтры; выбор строк с нулём frames; `setPhotosUploadedIfUnchanged` — stale no-op; `attachPhotos` merge/скоупинг/отсутствующая строка/сброс frames при сохранении metadata
- [ ] бонус-тесты (в Android покрыты только репо-тестами на фейках): `addMember` (set-семантика present/presentDetails, пересчёт `complete`, сброс `uploaded*`), `attachLocation`, version-guarded `markUploaded*IfUnchanged`/`…AndNoLocation`
- [ ] прогнать тесты — must pass before task 7

### Task 7: TrackStore + JudgeScanStore

**Files:**
- Create: `kolco24/Data/Stores/TrackStore.swift`, `kolco24/Data/Stores/JudgeScanStore.swift`
- Create: `kolco24Tests/Data/JudgeScanStoreTests.swift`, `kolco24Tests/Data/TrackStoreTests.swift`

- [ ] методы по инвентарю; `insertAll` c IGNORE (повторный UUID не дублируется), сортировки `COALESCE(...)`
- [ ] `JudgeScanStoreTests` ← `JudgeScanDaoTest.kt` (7 кейсов): скоупинг raceId; trusted-then-wall порядок; `markUploaded*` — только указанные строки; `pendingUploadRaces` distinct; `uploadCounts` по вставкам / независимость local-cloud / исключение чужих гонок
- [ ] `TrackStoreTests` (бонус): IGNORE-идемпотентность, порядок `observeForTeam`, дренаж с limit, `pendingUploadScopes`
- [ ] прогнать тесты — must pass before task 8

### Task 8: InstallId + ClockAnchorStore + TrustedClock.makeDefault()

**Files:**
- Create: `kolco24/Core/Stores/InstallId.swift`
- Create: `kolco24/Core/Time/ClockAnchorStore.swift`
- Modify: `kolco24/Core/Time/SystemClockProviders.swift` (фабрика `makeDefault()`)
- Create: `kolco24Tests/Core/InstallIdTests.swift`, `kolco24Tests/Core/ClockAnchorStoreTests.swift`

- [ ] `InstallId` ← `data/InstallId.kt`: get-or-create UUID через `load`/`save`-seam, ключ `install_id`; адаптер `UserDefaults.standard`
- [ ] `ClockAnchorStore` ← `data/time/ClockAnchorStore.kt`: ключ `anchor`, формат `"serverEpochMs|anchorElapsedMs|capturedWallMs|bootCount?"` 1:1, чистые parse/format, seam + адаптер; парсинг через `components(separatedBy: "|")`, ровно 4 компоненты (Swift `split` отбрасывает хвостовой пустой сегмент при `bootCount == nil` — см. Technical Details)
- [ ] `TrustedClock.makeDefault()`: системные провайдеры + `persist`/`persisted` из `ClockAnchorStore` (подключение к приложению — этапы 3–4)
- [ ] `InstallIdTests` ← `InstallIdTest.kt`, `ClockAnchorStoreTests` ← `ClockAnchorStoreTest.kt` (in-memory seam; round-trip, битые строки → nil, `bootCount` опционален)
- [ ] прогнать тесты — must pass before task 9

### Task 9: Verify acceptance criteria

- [ ] полный `xcodebuild test` зелёный (включая все ~193 существующих кейса этапов 0–1)
- [ ] grep-инварианты: `import GRDB` отсутствует в `kolco24/Model/` и `kolco24/Core/`; `import UIKit|SwiftUI` отсутствует в `Core/`, `Model/`, `Data/`
- [ ] UI не тронут: `git diff --stat` — ни один из 8 корневых UI-файлов не изменён; `project.pbxproj` не изменён
- [ ] сверка покрытия: `MarkDaoTest` 12/12, `CheckpointDaoTest` 4/4, `JudgeScanDaoTest` 7/7, 3 конвертер-теста, `InstallIdTest`, `ClockAnchorStoreTest` — все имеют Swift-зеркало; бонус-тесты помечены
- [ ] инвентарь store'ов: 12/12 DAO имеют store, все методы DAO перенесены (пройтись по списку из Technical Details)

### Task 10: [Final] Документация

**Files:**
- Modify: `docs/plans/android-port.md`
- Modify: `CLAUDE.md`

- [ ] в `android-port.md` пометить этап 2 ✅ со ссылкой на этот план (по образцу этапов 0–1)
- [ ] в `CLAUDE.md` описать `Data/` (AppDatabase, Records, Stores), правило «SQL дословно», grep-инварианты, key-value-сторы и что отложено (Theme/TrackProfile/AdminToken/RaceLease)
- [ ] переместить этот план в `docs/plans/completed/` (поправить ссылку в шапке на `../android-port.md`)

## Post-Completion

**Manual verification:**
- живая запись реальных серверных данных в базу — этап 3 (sync-репозитории поверх store'ов);
- поведение `DatabasePool`/WAL на реальном устройстве под фоновыми обращениями — по мере появления фоновых фич (этапы 6, 8).

**External system updates:**
- в Android-репо можно завести реальные SQL-тесты для 9 непокрытых DAO по образцу наших бонус-тестов; вне скоупа этого плана.
