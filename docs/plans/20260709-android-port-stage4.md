# Этап 4 портирования: подключение существующего UI к реальным данным

Детализация этапа 4 из [android-port.md](../plans/android-port.md). Этапы 0–3 выполнены: чистая логика (`Core/`, `Model/`), GRDB-слой (`Data/`), сеть и 4 sync-репозитория (`Net/`, `Data/Repositories/`) готовы и покрыты тестами.

## Overview

Заменить мок-массивы в трёх вкладках (`MarksView`, `LegendView`, `TeamView`) на реальные данные из БД с реактивным обновлением, и построить флоу выбора гонки/команды (CompPicker → TeamPicker → подтверждение). Плюс: пустые состояния, refresh-оркестрация (старт / смена команды / pull-to-refresh), показ ошибок refresh.

**Ключевая адаптация под платформу (требование: не 1в1 из Kotlin).** В Android у этих экранов **нет** ViewModel-слоя — всё состояние живёт в одном 2220-строчном composable `Kolco24AppRoot` (`MainActivity.kt`): он `collectAsState()`-ит Flow всех репозиториев и считает derived-значения инлайн. Копировать нечего — на iOS проектируется идиоматичный слой `@Observable`-моделей (target iOS 18):

- `AppEnvironment` — composition root (аналог `AppContainer.kt`): БД, клиенты, сторы, репозитории;
- `AppModel` (`@Observable @MainActor`) — кросс-экранное состояние (selected team) + оркестрация refresh;
- per-tab модели `MarksModel` / `LegendModel` / `TeamModel` / `TeamPickerModel` — подписки на GRDB `AsyncValueObservation` + derived-значения.

**Чистая derived-логика при этом переносится 1:1 вместе с Kotlin-тестами** — она в Android вынесена в pure-функции (`TeamPickerLogic.kt`, `DateUtils.kt`, хелперы `MarkRepository.kt`, `ui/legend/*`, `ui/marks/*`) и является спецификацией поведения.

Вне скоупа (по мастер-плану): NFC-скан и привязка чипов (этап 5 — кнопка «Привязать» остаётся видимой заглушкой; `ScanSheet` не трогаем), загрузка на сервер (этап 6), фото (этап 7 — `PhotoTile`/лайтбокс остаются заглушкой), LAN/`SyncCoordinator`/lease (этап 9 — источник всегда `.cloud`, `isRacePinned` остаётся `false`). Ввода кода разблокировки легенды нет и в Android (reveal только по NFC-скану — этап 5).

## Context (from discovery)

- **Kotlin-источники** (относительно `app/src/main/java/ru/kolco24/kolco24/` в `/Users/alff0x1f/src/kolco24_app_v2`): `MainActivity.kt` (`Kolco24AppRoot` — референс поведения, не структуры), `Kolco24App.kt` (стартовые Launch A/B refresh-корутины), `AppContainer.kt`, `data/DateUtils.kt`, `data/MarkRepository.kt` (чистые `takenPoints`/`takenPointCount`/`totalScore`), `ui/teampicker/TeamPickerLogic.kt` + `CompPickerScreen.kt`/`TeamPickerScreen.kt`/`TeamSwitchSheet.kt`/`TeamEmptyContent.kt`, `ui/legend/LegendScreen.kt` + `CheckpointColor.kt`, `ui/marks/MarksScreen.kt`, `ui/team/TeamScreen.kt`, `ui/common/PullToRefresh.kt` (`refreshErrorMessage`).
- **Android-тесты для зеркалирования** (`app/src/test/java/ru/kolco24/kolco24/`): `ui/teampicker/TeamPickerLogicTest.kt` (39), `ui/legend/CheckpointColorTest.kt` (5) + `IsScoringTest.kt` (5) + `GroupCheckpointsByColorTest.kt` (6), `ui/marks/MarksMappingTest.kt` (41, фото-кейсы — этап 7) + `TileFillTest.kt` (5), чистая часть `data/MarkRepositoryTest.kt` (хелперы очков; DAO-часть уже зеркалирована в этапе 2). Для `DateUtils.kt` JVM-теста нет — `RaceDatesTests` целиком бонус.
- **Готово из этапов 1–3 (iOS):** сторы с observation (`SelectedTeamStore.observe()`, `TeamStore.observeTeamById/observeTeamsForRace/observeCategoriesForRace`, `RaceStore.observeRaces`, `CheckpointStore.observeCheckpointsForRace`, `MarkStore.observeForTeam`, `LegendMetaStore.observeForRace`, `MemberChipBindingStore.observeForTeam` + `deleteSlot`); репозитории `refreshRaces(source:)` / `refreshTeams(_:source:)` / `refreshLegend(_:source:)` / `refreshMemberTags(_:source:)` → `RefreshResult`; фабрика `ApiClients.makeDefaultPair()` (общие `TrustedClock.makeDefault()` + `InstallId`); `PluralRu`.
- **iOS UI сейчас:** 3 вкладки на мок-массивах (`CheckpointTile` в `MarksView`, `LegendCP` в `LegendView`, `TeamMember`/`ChipSlot` в `TeamView`/`ScanSheet`), дизайн-система готова (`DesignTokens`, `SharedComponents`). Визуальный дизайн вкладок сохраняется — меняется источник данных.
- **Синхронизированная группа:** новые подпапки `kolco24/App/`, `kolco24Tests/App/` попадают в таргеты автоматически, `project.pbxproj` не трогаем.

## Development Approach

- **testing approach**: порт-TDD для чистой логики — Android-тесты каждого модуля переносятся вместе с ним в той же задаче (сценарии и имена кейсов 1:1, header-комментарий «Зеркало …»); бонус-тесты сверх Kotlin помечаются `// MARK: - БОНУС-тесты`. Для моделей (`AppModel`, per-tab) Android-зеркала нет — тесты пишутся с нуля (regular: код → тесты в той же задаче) поверх in-memory БД + фейкового транспорта (конвенция этапа 3);
- complete each task fully before moving to the next;
- make small, focused changes (коммит на задачу или пару мелких);
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task;
- **CRITICAL: all tests must pass before starting next task**;
- **CRITICAL: update this plan file when scope changes during implementation**.

## Testing Strategy

- **unit tests**: Swift Testing. Чистая логика — `kolco24Tests/Core/` (зеркала Kotlin). Модели — `kolco24Tests/App/` поверх **реальных** сторов над `AppDatabase.makeInMemory()` (без фейков — конвенция этапа 2) + `FakeTransport` из этапа 3 для refresh-путей; `@MainActor`-тесты с ожиданием эмиссий observation (паттерн: записать в стор → дождаться обновления свойства модели с таймаутом).
- **e2e**: нет автоматизированных. Ручной прогон в симуляторе — задача верификации (выбор гонки → команды → реальная легенда/ростер с сервера).
- Прогон: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'` (нужен `Config/Secrets.xcconfig`; при флаки-имени — `id=<UDID>` из `xcrun simctl list devices available`).

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview

**Слой состояния (решение брейншторма): AppEnvironment → AppModel → per-tab модели.**

1. `App/AppEnvironment.swift` — обычный класс, создаётся один раз в `kolco24App`: `AppDatabase.makeShared()`, `ApiClients.makeDefaultPair()`, все нужные сторы и 4 репозитория. `AppEnvironment.inMemory(transport:)` — для тестов и превью (in-memory БД + фейковый транспорт); фабрика `ApiClients` транспорт-seam не имеет — `inMemory` собирает `ApiClient(...)` напрямую с `transport: fake.handle` (паттерн `makeApiClient` из `RaceRepositoryTests` этапа 3). Репозиторий-обёртка для привязок **не создаётся** — `MemberChipBindingStore` вызывается напрямую (YAGNI; Android-обёртка тривиальна).
2. `App/AppModel.swift` (`@Observable @MainActor`) — владеет:
   - подпиской на `selectedTeamStore.observe()` (long-running `Task` с `for await`);
   - разрешением `SelectedTeamState` (`none`/`loading`/`missing(teamId)`/`present(Team)`) — порт `produceState`-логики из `MainActivity.kt`: смена `selectedTeam` перезапускает вложенное наблюдение `teamStore.observeTeamById`;
   - **оркестрацией refresh** (порт Launch A/B из `Kolco24App.kt`, источник всегда `.cloud`): `start()` — `refreshRaces()` + префетч ближайшей гонки (`nearestRaceId`); реактивно — при смене `raceId` выбранной команды дёргает `refreshTeams`/`refreshLegend`/`refreshMemberTags`; `refreshAll()` — для pull-to-refresh на «Команде» (fan-out всех 4 для текущей гонки);
   - `toastMessage: String?` — последняя ошибка refresh (через `refreshErrorMessage`), успех молчалив;
   - созданием и обновлением per-tab моделей: при смене выбора вызывает `model.rebind(teamId:raceId:)`, который перезапускает observation-задачи. **Stale-data guard (порт `safeMarks`/`safeCheckpoints`/chips-guard из `MainActivity.kt` ~708–808):** между отменой старой observation-задачи и первой эмиссией новой в модели лежат строки прежней команды/гонки — `rebind` обязан очистить массивы (и сбросить loading-флаг) перед перезапуском, а derived-слой дополнительно фильтрует по актуальным `teamId`/`raceId` (в Android это ручные фильтры с комментарием «collectAsState does not reset on key change»; на iOS проблема идентична).
3. Per-tab модели (`@Observable @MainActor`, в `App/`): держат сырые данные из observation'ов + отдают derived-значения через чистые функции `Core/`. Вьюхи получают `AppModel` через `.environment(...)`.
4. Флоу выбора команды — идиоматичный iOS, **не** порт Android-оверлеев с `BackHandler`: `.fullScreenCover` → `NavigationStack` (`CompPickerView` → push `TeamPickerView`) → confirmation `.sheet` c `presentationDetents([.medium])`. Подтверждение → `selectedTeamStore.upsert` → закрыть cover; реактивный блок `AppModel` сам подтянет данные.

**Раскладка (новые файлы):**

| iOS-файл | Kotlin-источник | Тесты |
|---|---|---|
| `Core/Util/RaceDates.swift` | `data/DateUtils.kt` (`todayIso`, `effectiveEnd`, `nearestRaceId`) | `RaceDatesTests` (бонус — JVM-теста нет) |
| `Core/Team/TeamPickerLogic.swift` | `ui/teampicker/TeamPickerLogic.kt` | `TeamPickerLogicTests` (39) |
| `Core/Legend/LegendDisplay.swift` | `ui/legend/CheckpointColor.kt` + чистые функции `LegendScreen.kt` (`isScoring`, `groupCheckpointsByColor`) | `CheckpointColorTests` (5), `IsScoringTests` (5), `GroupCheckpointsByColorTests` (6) |
| `Core/Marks/MarkMetrics.swift` | чистые хелперы `data/MarkRepository.kt` (`takenPoints`/`takenPointCount`/`totalScore`) | `MarkMetricsTests` (чистая часть `MarkRepositoryTest.kt`) |
| `Core/Marks/MarksDisplay.swift` | чистые функции `ui/marks/MarksScreen.kt` (`marksToTiles`, `tileFill`, `hiddenTakenTokens`, `tokensLabel`, empty-лестница) | `MarksDisplayTests` (зеркала не-фото части `MarksMappingTest.kt` + `TileFillTest.kt`) |
| `Core/Sync/RefreshErrorMessage.swift` | `refreshErrorMessage` из `ui/common/PullToRefresh.kt` | `RefreshErrorMessageTests` |
| `App/AppEnvironment.swift` | `AppContainer.kt` | через тесты моделей |
| `App/AppModel.swift` | `Kolco24AppRoot`-состояние + Launch A/B из `Kolco24App.kt` | `AppModelTests` |
| `App/TeamPickerModel.swift`, `App/MarksModel.swift`, `App/LegendModel.swift`, `App/TeamModel.swift` | derived-вайринг `Kolco24AppRoot` | `TeamPickerModelTests` и т.д. |
| `CompPickerView.swift`, `TeamPickerView.swift`, `TeamConfirmSheet.swift` | `ui/teampicker/*Screen.kt` | ручная верификация |
| `EmptyStates.swift` (+ toast в `SharedComponents.swift`) | `TeamEmptyContent.kt`, `MarksEmpty` | через `MarksDisplayTests` (лестница) |

**Grep-инварианты (расширение этапов 1–3):** `import GRDB` — только под `Data/` (плюс `AsyncValueObservation` в сигнатурах сторов; в `App/`-моделях допускается `import GRDB` **только** ради типа `AsyncValueObservation` — если понадобится, предпочесть `typealias` в `Data/`; во вьюхах — никогда); `import UIKit|SwiftUI` — нигде под `Core/`, `Model/`, `Data/`, `Net/`; `App/`-модели без `import SwiftUI` (им хватает `Observation`).

## Technical Details

**`SelectedTeamState`** (порт `produceState`-цепочки `MainActivity.kt` ~683): `selected == nil` → `.none`; `selected != nil`, команда ещё не эмитирована → `.loading`; observation команды эмитировал `nil` → `.missing` («команда исчезла» — например, удалена сервером при resync); эмитировал `Team` → `.present(team)`. `loading` подавляет мигание empty-state.

**Refresh-оркестрация (`AppModel`, всё `.cloud`):**
- `start()` (вызывается один раз из `.task` корневой вьюхи): `refreshRaces()`; на `.updated`/`.notModified` — прочитать гонки, `nearestRaceId(races, todayIso())` → префетч `refreshTeams`/`refreshLegend`/`refreshMemberTags` (параллельно, результаты игнорируются — префетч best-effort, порт Launch A).
- Реактивный блок (порт Launch B): в подписке на `selectedTeam` при смене `raceId` — `refreshTeams(raceId)` + `refreshLegend(raceId)` + `refreshMemberTags(raceId)`; ошибки → `toastMessage`.
- `refreshAll()` (pull-to-refresh «Команды»): fan-out всех 4 refresh для текущей гонки, комбинированная ошибка — первая не-`updated`/`notModified`.
- Ошибка → строка: `refreshErrorMessage(RefreshResult) -> String?` — `nil` для `updated`/`notModified`/`skipped`; русские тексты для `offline`/`forbidden`/`httpError` — 1:1 из `PullToRefresh.kt`.

**`TeamPickerModel`:** наблюдает `raceStore.observeRaces()`; для выбранной гонки — `teamStore.observeTeamsForRace`/`observeCategoriesForRace`. Держит `searchQuery: String` и `load: PickerLoad` (`enum: loading/loaded/offline/httpError(Int)/forbidden` — порт маппинга из `TeamPickerScreen.kt`; при непустом кэше ошибка показывается toast'ом, список остаётся). Действия: `openedCompPicker()` → `refreshRaces`; `raceSelected(id)` → `refreshTeams` + фоновый префетч `refreshLegend` (порт `onRaceSelected`); `confirm(raceId:teamId:)` → `selectedTeamStore.upsert`. Derived через `TeamPickerLogic`: `splitRaces(races, today)` (текущие/архив по `effectiveEnd() >= today`), `raceStatusPill`, `filterTeams(teams, query)`, `peopleLine`/`peopleWord` (поверх `PluralRu`), `teamToken`, `displayTeamName`, `initials`.

**`MarksModel`:** наблюдает `markStore.observeForTeam(teamId)` + `checkpointStore.observeCheckpointsForRace(raceId)` + `legendMetaStore.observeForRace(raceId)` + `memberChipBindingStore.observeForTeam(teamId)` (для empty-лестницы). Derived (чистые функции `Core/Marks/`): `costOf` — живая цена из легенды с фолбэком на снапшот отметки (`checkpointCosts[mark.checkpointId] ?? mark.cost`); `takenKp = takenPointCount(marks, costOf)` (различные полные КП с costOf > 0); `takenScore = totalScore(marks, costOf)`; `tiles = marksToTiles(marks, costOf, colorOf)` → существующие `CheckpointTile` (тайл на полное взятие, старые первыми); `hiddenTakenTokens(marks, lockedIds)` → нотис «взято, баллы неизвестны»; метрики ВЗЯТО `takenKp/totalKp` (`legendMeta.scoringCount`), СУММА `takenScore/totalCost` (`legendMeta.totalCost`), ДО КВ — «—» (плейсхолдер, как в Android — источника нет). Empty-лестница (урезанный порт `MarksEmpty`, NFC-ветки — этап 5): `loading` → ничего; нет команды → «выбери команду»; `boundCount < memberCount` → нудж «привяжи чипы» (переход на вкладку Команда); иначе → «готов к отметке». Фото-derived (`photoReviewSummary`, лайтбокс) — **не портируются** (этап 7).

**`LegendModel`:** наблюдает `checkpointStore.observeCheckpointsForRace` + `legendMetaStore.observeForRace` + `markStore.observeForTeam` (для `takenIds`). Derived: `takenIds = takenPoints(marks)`; `takenScore` (сумма cost взятых), `takenScoring`, `lockedCount`; прогресс ScoreCard = `takenScore/legendMeta.totalCost` (**не** суммировать cost клиентом — locked-КП скрывают цену); `isScoring(cp) = cp.locked || (cp.cost ?? 0) > 0`; `groupCheckpointsByColor` (карточки из подряд идущих КП одного цвета); `parseCheckpointColor` → маппинг на цвета дизайн-системы. Существующий `LegendCP` строится из `Checkpoint`; locked-строка — скелетон-бары (ширины детерминированы от `cp.id`, порт `LockedCheckpointRow`) + карточка «Скрыто N КП» при `lockedCount > 0`. Фильтр «Все N / Не взятые N» сохраняется. Pull-to-refresh → `refreshLegend`.

**`TeamModel`:** ростер из `team.members` (`[TeamMemberItem]`), `bindings: [Int: MemberChipBinding]` из `observeForTeam` по `numberInTeam`; `boundCount`/`allBound` (`totalCount = team.ucount`); hero «N / total с чипом». «Привязать» — видимая заглушка (алерт «Привязка чипов — в следующей версии» либо disabled — решить при реализации, стиль как в Android c выключенным NFC). **Отвязка входит в этап** (чисто БД): long-press участника → confirm-диалог → `memberChipBindingStore.deleteSlot(teamId:numberInTeam:)`. Строка «Сменить команду» → флоу выбора.

**Флоу выбора (вьюхи).** `CompPickerView`: секции «Текущие»/«Архив» (`splitRaces`), пилюля статуса (`raceStatusPill`), автообновление при открытии (`.task` → `refreshRaces`), pull-to-refresh. `TeamPickerView`: `.searchable` (порт `filterTeams`), группировка по категориям (сортировка `sortOrder`), состояние `PickerLoad`. `TeamConfirmSheet`: карточка команды (название `displayTeamName`, номер `teamToken`, категория, `peopleLine`, инициалы участников) + CTA «Выбрать» → `confirm` → dismiss всего cover. Открытие флоу: из empty-состояний всех вкладок и из строки «Сменить команду» в `TeamView`. Дизайн — существующая дизайн-система (DesignTokens, mono, карточки), UI на русском.

**Toast:** маленький компонент в `SharedComponents.swift` (капсула снизу над таб-баром, авто-скрытие ~3 с), рендерится overlay'ем в `ContentView` по `appModel.toastMessage`.

**Правило для view-структур:** существующие `CheckpointTile`/`LegendCP`/`TeamMember` перестают быть моками — либо строятся мапперами из доменных типов, либо заменяются доменными типами напрямую, где маппер тривиален (решить по месту; мок-массивы удаляются полностью).

## Implementation Steps

### Task 1: Чистая логика — TeamPickerLogic + RaceDates

**Files:**
- Create: `kolco24/Core/Util/RaceDates.swift`
- Create: `kolco24/Core/Team/TeamPickerLogic.swift`
- Create: `kolco24Tests/Core/RaceDatesTests.swift`
- Create: `kolco24Tests/Core/TeamPickerLogicTests.swift`

- [x] `RaceDates` ← `data/DateUtils.kt`: `todayIso()` (локальная дата `yyyy-MM-dd`; в чистой функции — параметр `Date`/провайдер, без скрытого `Date()`), `effectiveEnd(race)` (Kotlin: `dateEnd ?: date` — в iOS-модели `Race` поле называется `date`, не `dateStart`), `nearestRaceId(races, today)`
- [x] `TeamPickerLogic` ← `ui/teampicker/TeamPickerLogic.kt`: `splitRaces`, `RaceStatusPill`/`raceStatusPill`, `filterTeams`, `peopleLine`/`peopleWord` (поверх готового `PluralRu`), `teamToken`, `displayTeamName`, `initials`
- [x] `TeamPickerLogicTests` ← `TeamPickerLogicTest.kt` (39 кейсов, header «Зеркало …»)
- [x] `RaceDatesTests` — бонус-сьют (JVM-зеркала нет, задокументировать в шапке): edge-кейсы `effectiveEnd`/`nearestRaceId` (пустой список, все в прошлом, ties)
- [x] прогнать тесты — must pass before task 2

### Task 2: Чистая логика — Legend + Marks derived + refreshErrorMessage

**Files:**
- Create: `kolco24/Core/Legend/LegendDisplay.swift`
- Create: `kolco24/Core/Marks/MarkMetrics.swift`
- Create: `kolco24/Core/Marks/MarksDisplay.swift`
- Create: `kolco24/Core/Sync/RefreshErrorMessage.swift`
- Create: `kolco24Tests/Core/LegendDisplayTests.swift`
- Create: `kolco24Tests/Core/MarkMetricsTests.swift`
- Create: `kolco24Tests/Core/MarksDisplayTests.swift`
- Create: `kolco24Tests/Core/RefreshErrorMessageTests.swift`

- [x] `LegendDisplay` ← `ui/legend/CheckpointColor.kt` + чистые функции `LegendScreen.kt`: `parseCheckpointColor`, `isScoring`, `groupCheckpointsByColor`, скелетон-ширины locked-строки (детерминированы от `cp.id`)
- [x] `MarkMetrics` ← чистые хелперы `data/MarkRepository.kt`: `takenPoints`, `takenPointCount` (обе перегрузки), `totalScore` (обе перегрузки)
- [x] `MarksDisplay` ← чистые функции `ui/marks/MarksScreen.kt` (без фото): `marksToTiles` (+ `costOf`/`colorOf`-джойны), `tileFill`/`TileFill`, `hiddenTakenTokens`, `tokensLabel`, empty-лестница (`enum MarksEmptyState`: `none/chooseTeam/bindChips/ready` — NFC-ветки этапа 5 не портируются)
- [x] `RefreshErrorMessage` ← `refreshErrorMessage` из `ui/common/PullToRefresh.kt`: `RefreshResult → String?`, русские тексты 1:1
- [x] `LegendDisplayTests` ← `CheckpointColorTest.kt` (5) + `IsScoringTest.kt` (5) + `GroupCheckpointsByColorTest.kt` (6)
- [x] `MarkMetricsTests` ← чистая часть `MarkRepositoryTest.kt` (кейсы `takenPoints*`/`totalScore*`; DAO-кейсы уже зеркалированы `MarkStore`-тестами этапа 2 — не дублировать)
- [x] `MarksDisplayTests` ← не-фото кейсы `MarksMappingTest.kt` + `TileFillTest.kt` (5); фото-кейсы перечислить в шапке как «этап 7»; лестница empty-состояний — бонус-кейсы по урезанной логике
- [x] `RefreshErrorMessageTests`: все ветки `RefreshResult`
- [x] прогнать тесты — must pass before task 3

### Task 3: AppEnvironment + AppModel (selected team + refresh-оркестрация)

**Files:**
- Create: `kolco24/App/AppEnvironment.swift`
- Create: `kolco24/App/AppModel.swift`
- Modify: `kolco24/kolco24App.swift`
- Create: `kolco24Tests/App/AppModelTests.swift`

- [x] `AppEnvironment`: прод-инициализатор (`AppDatabase.makeShared()`, `ApiClients.makeDefaultPair()`, сторы, 4 репозитория) + `AppEnvironment.inMemory(transport:)` для тестов/превью
- [x] `AppModel` (`@Observable @MainActor`): подписка на `selectedTeamStore.observe()`, разрешение `SelectedTeamState` (`none/loading/missing/present`) с перезапуском вложенного `observeTeamById`, свойства `selectedRaceId`/`selectedTeamId`
- [x] refresh-оркестрация: `start()` (Launch A: `refreshRaces` + префетч ближайшей гонки через `nearestRaceId`), реактивный refresh при смене `raceId` (Launch B), `refreshAll()`, `selectTeam(raceId:teamId:)`/`clearTeam()`; ошибки → `toastMessage` через `refreshErrorMessage`
- [x] вайринг в `kolco24App.swift`: создать `AppEnvironment`/`AppModel`, `.environment(...)`, `start()` из `.task` корневой вьюхи (мок-данные вкладок пока не трогаются — вкладки переключаются в задачах 5–7)
- [x] `AppModelTests` (in-memory БД + `FakeTransport`): none→loading→present; missing при удалении команды; `selectTeam` персистит и переключает состояние; `start()` дёргает `/app/races/` и префетчит ближайшую гонку (проверка по журналу транспорта); смена команды дёргает teams/legend/member_tags; ошибка refresh → `toastMessage`, успех → nil
- [x] прогнать тесты — must pass before task 4 (всё зелёное: 591 тест, 0 падений; `AppModelTests` 10/10)

  ⚠️ Побочный фикс: `FakeTransport` (этап 3) стал потокобезопасным (`@unchecked Sendable` + `NSLock`) — параллельные `async let` fan-out'ы этапа 4 бьют `handle` из нескольких задач разом, без замка одновременная мутация `queue`/`recorded` = UB. Проверка путей в тестах — по `url.absoluteString` (а не `url.path`, который срезает завершающий слэш подписанного пути).

### Task 4: Флоу выбора гонки/команды (TeamPickerModel + вьюхи)

**Files:**
- Create: `kolco24/App/TeamPickerModel.swift`
- Create: `kolco24/CompPickerView.swift`
- Create: `kolco24/TeamPickerView.swift`
- Create: `kolco24/TeamConfirmSheet.swift`
- Modify: `kolco24/SharedComponents.swift` (toast-компонент)
- Modify: `kolco24/ContentView.swift` (toast-overlay + `.fullScreenCover` флоу)
- Create: `kolco24Tests/App/TeamPickerModelTests.swift`

- [x] `TeamPickerModel`: observation гонок/команд/категорий, `searchQuery`, `PickerLoad`, действия `openedCompPicker`/`raceSelected` (refresh + префетч легенды)/`confirm` (через `AppModel.selectTeam`)
- [x] `CompPickerView`: секции текущие/архив, пилюли статуса, автообновление, pull-to-refresh
- [x] `TeamPickerView`: `.searchable`, группировка по категориям, состояния `PickerLoad` (stale-кэш → toast, список остаётся)
- [x] `TeamConfirmSheet` (`presentationDetents([.medium])`): карточка команды + «Выбрать» → confirm → dismiss cover
- [x] toast-компонент в `SharedComponents` + overlay в `ContentView` по `appModel.toastMessage`; `.fullScreenCover` флоу поверх `NavigationStack` (постоянные точки входа — CTA empty-состояний и «Сменить команду» — появляются в задаче 5; для ручной проверки здесь допустим временный триггер)
- [x] `TeamPickerModelTests` (in-memory + `FakeTransport`): фильтрация/группировка через модель, `raceSelected` дёргает teams+legend, `PickerLoad`-маппинг из `RefreshResult` (offline/forbidden/httpError), `confirm` записывает `selected_team`
- [x] прогнать тесты — must pass before task 5 (596 unit-тестов зелёные, `TeamPickerModelTests` 9/9)

### Task 5: Вкладка «Команда» на реальных данных

**Files:**
- Create: `kolco24/App/TeamModel.swift`
- Create: `kolco24/EmptyStates.swift`
- Modify: `kolco24/TeamView.swift`
- Create: `kolco24Tests/App/TeamModelTests.swift`

- [x] `TeamModel`: `rebind(teamId:)` перезапускает `observeForTeam` привязок; derived `boundCount`/`allBound`, статус чипа по `numberInTeam` (плюс observation категорий гонки — `category(for:)` для герой-строки; `rebind(teamId:raceId:)`)
- [x] `EmptyStates.swift` ← `TeamEmptyContent.kt`: «выбери команду» (CTA → флоу) и «команда не найдена» (missing) — переиспользуются вкладками
- [x] `TeamView`: мок-массивы удалить; hero из реальной `Team` (порт полей: название, `teamToken`, категория, «N / total с чипом»), ростер из `team.members` + статус привязки; «Привязать» — заглушка до этапа 5 (алерт); long-press → confirm → `deleteSlot` (отвязка); «Сменить команду» → флоу; pull-to-refresh → `refreshAll()`; empty/missing-состояния. Временный триггер флоу в `ContentView` удалён — точка входа теперь `onChooseTeam`.
- [x] `TeamModelTests`: boundCount/allBound от записей в сторе, реакция на upsert/deleteSlot (observation), rebind при смене команды; **stale-guard**: привязки команды A → rebind на команду B → строки A не отображаются до эмиссии B (8/8)
- [x] прогнать тесты — must pass before task 6 (весь suite зелёный: `TeamModelTests` 8/8)

### Task 6: Вкладка «Легенда» на реальных данных

**Files:**
- Create: `kolco24/App/LegendModel.swift`
- Modify: `kolco24/LegendView.swift`
- Create: `kolco24Tests/App/LegendModelTests.swift`

- [x] `LegendModel`: observation checkpoints/legendMeta/marks; derived через `LegendDisplay`/`MarkMetrics` (`takenIds`, `takenScore`, `takenScoring`, `lockedCount`, прогресс `takenScore/totalCost`). ⚠️ Отступление: цвет-группы (`groupCheckpointsByColor`) в модель НЕ выведены — существующий iOS-дизайн вкладки плоский список (не цвет-карточки Android), функция остаётся Core-уровня (покрыта `LegendDisplayTests`); модель отдаёт `visibleCheckpoints(showOnlyOpen:)` (плоский фильтр). `isScoring` из `LegendDisplay` используется в `takenScoring`.
- [x] `LegendView`: мок-массив удалён; строки из `Checkpoint` (locked → скелетон-строка с `lockedSkeletonBars`, карточка «Скрыто N КП» через `DarkHeroBackground`); ScoreCard от `legend_meta` (`total_cost`/`scoring_count`, «/0» скрыт); фильтр «Все/Не взятые»; pull-to-refresh → `AppModel.refreshLegend`; empty/`missing` без команды через `TeamEmptyState` (онбординг), `.loading` подавляет мигание
- [x] `LegendModelTests` (in-memory): derived-значения от засеянных строк (locked/open/taken/технический cost 0), реакция на reveal (`checkpointStore.reveal`), на новое взятие и на смену команды/гонки; **stale-guard**: КП/marks гонки A → rebind на гонку B → строки A не участвуют в derived до эмиссии B (8/8)
- [x] прогнать тесты — must pass before task 7 (полный suite зелёный: 616 «passed on», 0 падений; `LegendModelTests` 8/8)

### Task 7: Вкладка «Отметки» на реальных данных

**Files:**
- Create: `kolco24/App/MarksModel.swift`
- Modify: `kolco24/MarksView.swift`
- Create: `kolco24Tests/App/MarksModelTests.swift`

- [x] `MarksModel`: observation marks/checkpoints/legendMeta/bindings; derived через `MarkMetrics`/`MarksDisplay` (`tiles`, `takenKp`, `takenScore`, `hiddenTakenTokens`, метрики, empty-лестница с подавлением до первой эмиссии — порт `marksLoading`)
- [x] `MarksView`: мок-массив удалить; грид из `tiles`, `MetricsCard` (ВЗЯТО/СУММА реальные, ДО КВ «—»), нотис hidden-taken; empty-лестница (выбрать команду / привязать чипы с переходом на вкладку Команда / готов); `PhotoTile`/CTA и `ScanSheet` остаются заглушками (этапы 5/7). Точки входа: `onChooseTeam` (флоу выбора) и `onBindChips` (переход на вкладку «Команда») из `ContentView`; `.missing` рендерит `TeamEmptyState(missing:)`, pull-to-refresh → `refreshAll`
- [x] `MarksModelTests` (in-memory): tiles/метрики от засеянных marks+checkpoints (живая цена и фолбэк на снапшот, полные/неполные взятия), hidden-taken при locked, лестница empty-состояний (нет команды / не привязаны / готов), подавление до первой эмиссии; **stale-guard**: marks команды A → rebind на команду B → тайлы/метрики A не засчитаны B (порт `safeMarks`)
- [x] прогнать тесты — must pass before task 8 (полный suite зелёный, `MarksModelTests` 9/9)

### Task 8: Verify acceptance criteria

- [ ] полный `xcodebuild test` зелёный (все этапы 0–4)
- [ ] сверка зеркал: `TeamPickerLogicTests` 39/39, `LegendDisplayTests` 16/16, `MarksDisplayTests` (не-фото кейсы `MarksMappingTest` + 5 `TileFillTest`), `MarkMetricsTests` (чистая часть), headers «Зеркало …», бонусы под `// MARK: - БОНУС-тесты`
- [ ] grep-инварианты: `import UIKit|SwiftUI` отсутствует в `Core/`/`Model/`/`Data/`/`Net/`; `App/`-модели без `import SwiftUI`; `import GRDB` вне `Data/` — не появился во вьюхах (допустим typealias-костыль, если понадобился, — задокументировать)
- [ ] мок-массивы удалены: `grep` по старым мок-данным (`CheckpointTile(number:` литералы и т.п.) в `MarksView`/`LegendView`/`TeamView` — пусто
- [ ] ручной прогон в симуляторе против живого сервера: пустой старт → «выбери команду» → CompPicker (реальные гонки) → TeamPicker (поиск, категории) → подтверждение → вкладки наполняются (легенда с locked-скелетонами, ростер, метрики нулевые); pull-to-refresh на всех экранах; авиарежим → toast оффлайна, кэш остаётся
- [ ] тёмная тема: беглый прогон новых экранов (CompPicker/TeamPicker/confirm/empty/toast) в dark mode — токены адаптивные, литералов white/black нет

### Task 9: [Final] Документация

**Files:**
- Modify: `docs/plans/android-port.md`
- Modify: `CLAUDE.md`

- [ ] в `android-port.md` пометить этап 4 ✅ со ссылкой на этот план (по образцу этапов 0–3)
- [ ] в `CLAUDE.md`: раздел про `App/` (AppEnvironment/AppModel/per-tab модели, SelectedTeamState, refresh-оркестрация, toast), обновить «Data model pattern» (мок-массивы больше не существуют), флоу выбора команды, новые `Core/`-модули, обновлённые grep-инварианты
- [ ] переместить этот план в `docs/plans/completed/` (поправить ссылку в шапке на `../android-port.md`)

## Post-Completion

**Manual verification:**
- NFC-скан → реальное взятие → живой тайл на «Отметках» — этап 5 (сейчас marks пишутся только тестами/вручную в БД);
- привязка чипа с реального браслета — этап 5 (сейчас только отвязка и отображение статуса);
- «ДО КВ» в метриках остаётся плейсхолдером до появления источника (finish_time гонки — решится в этапах 5–6).

**External system updates:**
- нет: серверный контракт не меняется, Android-репо не затрагивается.
