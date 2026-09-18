# Чек-лист готовности к старту (вкладка «Отметки»)

## Overview

Перед соревнованием пользователь делает несколько разрозненных действий: выбирает соревнование и
команду, привязывает NFC-чипы участникам, даёт геодоступ, качает оффлайн-подложку карты. Сейчас это
размазано по вкладкам и всплывает по одному шагу за раз (`MarksEmptyLadder` показывает ровно один
следующий шаг), так что проверить «всё ли готово» одним взглядом нельзя.

Задача — показать единый список готовности на вкладке «Отметки», видимый пока не взято ни одного КП
(`tiles.isEmpty`). Семь пунктов, каждый со статусом и действием. Список заменяет лестницу
`MarksEmptyLadder`.

**Состав (порядок фиксирован в коде, не сортируется по статусу — прыгающие строки хуже одного
пункта ниже по списку):**

| # | Пункт | Статус при невыполнении | Источник сигнала |
|---|-------|------------------------|------------------|
| 1 | Команда выбрана | `blocked` | `AppModel.selectedTeamState` |
| 2 | Чипы привязаны N/N | `blocked` | `MarksModel.bindings` |
| 3 | Геолокация (доступ + полная точность) | `warning` | `AppEnvironment.locationAuthorization` / `isReducedAccuracy` |
| 4 | Легенда загружена | `warning` | `MarksModel.checkpoints` |
| 5 | Карта скачана | `warning` | `Race.mapUrl` + `AppEnvironment.mapFileExists` |
| 6 | Часы синхронизированы | `warning` | `AppModel.clockStatus` |
| 7 | Энергосбережение выключено | `warning` | `ProcessInfo.isLowPowerModeEnabled` |

`blocked` — без этого отметка физически не сработает. `warning` — качество данных страдает, но
отметиться можно. Пункт карты **скрыт целиком**, если у гонки нет `mapUrl` (иначе чек-лист вечно
неполный). Пункт энергосбережения виден **только когда Low Power Mode включён** (галочка «выключено»
не несёт информации).

**Сознательно исключено:**

- **Уведомления.** На iOS они не нужны для фонового трека — он уже обеспечен `UIBackgroundModes:
  location` (`kolco24/Info.plist`) + `CLBackgroundActivitySession`
  (`kolco24/Location/CoreLocationTrackEngine.swift:55`). Это андроидная механика (foreground service
  требует нотификацию), на iOS показывается синий индикатор в статус-баре.
- **Уровень заряда в процентах.** `UIDevice.batteryLevel` потребовал бы нового `Device/` адаптера и
  правки grep-инварианта ради строки, которую пользователь и так видит в статус-баре. Low Power Mode
  — реальный сигнал (душит фоновые обновления локации), заряд — нет.

## Context (from discovery)

**Файлы/компоненты:**

- `kolco24/MarksView.swift:437` — ветка `tiles.isEmpty` рендерит `MarksEmptyLadder`; сюда встаёт
  карточка. `MarksView.swift:115` уже наблюдает `scenePhase`.
- `kolco24/App/MarksModel.swift` — уже держит `bindings`, `checkpoints`, `legendMeta` (три из семи
  сигналов бесплатно) и `emptyState(hasTeam:members:)` (строка 206).
- `kolco24/Core/Marks/MarksDisplay.swift:204-227` — `MarksEmptyState` + `marksEmptyState`.
- `kolco24/App/MapModel.swift:166` — `refreshAvailability()`, образец one-shot чтения `mapUrl`.
- `kolco24/App/AppEnvironment.swift:134,147,149,152` — `mapFileExists`, `hasLocationAccess`,
  `isReducedAccuracy`, `requestLocationAuthorization`. **Четыре места правки, не два**: `private init`
  (`:156`) держит список параметров (`:175-183`) **и** единственный блок присваиваний (`:195-203`);
  `makeShared()` (`:367`) передаёт прод-замыкания (`:414-424`); `inMemory()` (`:431`) имеет
  **свой** список параметров с дефолтами (`:442-450`) плюс проброс (`:496-504`).
- `kolco24/Location/CoreLocationTrackEngine.swift:146` — `hasLocationAccess()` над удерживаемым
  `CLLocationManager`.
- `kolco24/Core/Time/TrustedClock.swift:52` — `ClockStatus {noSync, ok, skewed(skewMs:)}`.
- `kolco24/ContentView.swift:15,26` — `@State selectedTab`, образец `onBindChips: { selectedTab = 3 }`.
- `kolco24/TeamView.swift` — `MiscRowView`, образец стиля строки с действием.
- `kolco24/PhotoCaptureView.swift:18-19,224` — ссылка в Настройки через `@Environment(\.openURL)` схемой
  `app-settings:`, **осознанно без UIKit-константы** `openSettingsURLString`. `import UIKit` в проекте
  живёт только в `DesignTokens.swift` и `Audio/ScanFeedbackPlayer.swift`.
- `kolco24/App/AppModel.swift:64` — `env` приватен, наружу `requestLocationAuthorization` не отдаётся
  (форвардится только в `TrackRecorder`, `:100`); `refreshAll()` (`:622`) — `async`.

**Патерны проекта, которым следуем:**

- Чистая логика в `Core/` (только `Foundation`), derived-функция из снимка входов — идиома
  `marksEmptyState`/`marksToTiles`.
- Инжектированные замыкания для системных зависимостей (идиома `TrustedClock`).
- Stale-guard при `rebind`: синхронный сброс производных до первой эмиссии + проверка
  `boundRaceId == raceId` после `await`.
- Тесты: чистые таблицы для `Core/`, реальные сторы над `AppDatabase.makeInMemory()` для `App/`
  (БД не фейкаем никогда).

**Зависимости:** новых внешних нет. `ProcessInfo` — `Foundation`.

## Development Approach

- **testing approach**: Regular (код, затем тесты в той же задаче)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
- **CRITICAL: all tests must pass before starting next task**
- **CRITICAL: update this plan file when scope changes during implementation**
- **Ветка от `main`, коммиты в `main` запрещены; финал — PR.**

## Testing Strategy

- **unit tests**: обязательны в каждой задаче.
  - `kolco24Tests/Core/` — чистые таблицы без моков.
  - `kolco24Tests/App/` — реальные сторы над `AppDatabase.makeInMemory()`, системные зависимости
    подменяются через тестовый инициализатор `AppEnvironment`.
- **e2e тесты**: в проекте отсутствуют (UI-тестов нет, платформенные адаптеры device-only).
- **гейт задачи и всего плана**:
  ```bash
  xcodebuild -project kolco24.xcodeproj -scheme kolco24 \
    -destination 'platform=iOS Simulator,name=iPhone 16' build
  xcodebuild test -project kolco24.xcodeproj -scheme kolco24 \
    -destination 'platform=iOS Simulator,name=iPhone 16'
  ```
  Требуется `Config/Secrets.xcconfig` — без него падают и сборка, и тесты.

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Solution Overview

**Выбранный подход: расширить `MarksModel`** (рассматривались и отклонены: отдельная
`ReadinessModel` — два параллельных observation'а по одним и тем же таблицам ради одного экрана,
YAGNI; сборка в `AppModel` — потребовала бы всегда-живых наблюдений привязок и КП ради одной
вкладки).

Слои:

1. **`Core/Readiness/ReadinessChecklist.swift`** — чистая функция `readinessItems(ReadinessInput) ->
   [ReadinessItem]`. Ноль фреймворков, вся логика статусов, скрытия пунктов и русских текстов здесь,
   полностью покрывается табличными тестами. Плюс (по итогам ревью) производные шапки
   `readinessSummary(_:)` и гейт первой отрисовки `readinessCardVisible(...)` — тоже чистые.
2. **`AppEnvironment`** — два новых инжекта: `isLowPowerMode` и трёхзначный `locationAuthorization`.
3. **`MarksModel`** — собирает снимок: три существующих observation'а + `mapUrl` из БД (читается в
   `rebind` и перечитывается на каждом опросе) + синхронный опрос устройства (`refreshDeviceState()`),
   отдаёт `readinessCard(...)` (и `readiness(...)` без гейта — для тестов).
4. **`MarksView`** — `ReadinessCard` вместо `MarksEmptyLadder`; `ContentView` добавляет `onOpenMap`.

**Ключевые решения:**

- **Трёхзначный геостатус.** Существующий `hasLocationAccess() -> Bool` схлопывает `.notDetermined` и
  `.denied` в `false`, поэтому тап по пункту всегда вёл бы в Настройки iOS — там, где при
  `.notDetermined` хватило бы системного диалога в два тапа. Новый инжект
  `locationAuthorization() -> LocationAuthorization` читает статус как три значения; `.notDetermined`
  → `requestLocationAuthorization()`, `.denied` → Настройки. **`hasLocationAccess` не удаляем** —
  им пользуется `TrackRecorder` для TOCTOU-проверки перед стартом записи.
- **Карта — read-only.** `MarksModel` узнаёт `mapUrl` тем же one-shot чтением `raceStore.getById`,
  что и `MapModel.refreshAvailability`, но без машины скачивания: CTA ведёт на вкладку «Карта», где
  уже есть весь UI прогресса, отмены и ошибок. Дублировать скачивание ради карточки не нужно.
- **Опрос устройства, а не наблюдение.** Геостатус и Low Power Mode меняются вне приложения
  (Настройки iOS), поэтому это синхронный опрос, а не observation.
- **Файл карты тоже перечитывается опросом.** `rebind` рано выходит на неизменённой паре
  `(teamId, raceId)` (`MarksModel.swift:70`), а вкладки в `TabView` живут вечно, так что вычисления
  один раз в `rebind` не хватит: пользователь видит «Карта не скачана» → уходит на вкладку «Карта» →
  качает → возвращается, а пункт всё ещё красный (переключение вкладки не меняет `scenePhase`, а
  `.task` отрабатывает один раз за жизнь вьюхи). `MapModel` решает это тем же способом —
  `refreshAvailability()` зовётся из `MapTabView` на появлении («файл-как-флаг не наблюдаем»,
  `MapModel.swift:151-158`). Поэтому опрос (`refreshDeviceState()`, зовётся из `.task`, `onAppear` и на
  `scenePhase == .active`) перечитывает **обе** составляющие пункта карты.
  ⚠️ Уточнено на ревью (round 2): изначально предполагалось читать `mapUrl` один раз в `rebind` и опрашивать
  только наличие файла. В коде `refreshDeviceState()` перечитывает `mapUrl` из БД **безусловно** (паритет с
  `MapModel.refreshAvailability`), а не «пока он `nil`»: сервер шлёт `""` как «карты нет», и гард по значению
  выключил бы опрос навсегда. `loadMapUrl` нормализует `""` в `nil` и пересчитывает `mapReadiness`, только если
  строка гонки реально изменилась; единственный гард — флаг `isLoadingMapUrl` (чтение уже в полёте).
- **Ссылка в Настройки — через `@Environment(\.openURL)` и схему `app-settings:`**, а не
  `UIApplication.openSettingsURLString`: ровно так уже сделано в `PhotoCaptureView.swift:224`, и это
  сохраняет grep-инвариант «UIKit только в `DesignTokens` и `Audio/`».
- **Запрос геодоступа идёт через `MarksModel`**, а не через `AppModel`: `AppModel.env` приватен и
  метода-обёртки не имеет, а `MarksModel` уже держит `env`. Добавляем `MarksModel.requestLocationAccess()`
  рядом с `refreshDeviceState()` — `AppModel` не трогаем.
- **Выполненные пункты остаются видимыми**, приглушёнными. Пользователь просил «удобно проверить,
  что всё есть» — исчезающие галочки этого не дают, а семь строк — короткий список.
- **Гейт первой отрисовки — пять сигналов, а не `marksLoading`.** ⚠️ Уточнено на ревью (round 2), дополнено
  в round 4: карточка рисует ТРИ независимых observation'а (взятия, привязки, КП гонки), опрошенное состояние
  устройства и одиночное чтение `races.map_url` из БД, а порядка между ними нет, поэтому гейт по одному
  `marksLoading` пропускал кадр с пустым снимком (красное «Чипы привязаны не всем · 0 из N» у полностью
  привязанной команды), а гейт без пятого сигнала — ложное свёрнутое «Всё готово к старту», через миг
  разворачивающееся строкой «Карта не скачана». Решение вынесено в чистую
  `readinessCardVisible(marksLoading:bindingsLoading:checkpointsLoading:deviceStatePolled:mapUrlResolved:)`
  (`Core/Readiness/`), которую зовёт `MarksModel.readinessCard(...)`; вьюха только разворачивает `nil`.
  `mapUrlResolved` взводится один раз за привязку (`raceId == nil` — синхронно в `rebind`, иначе в теле
  `loadMapUrl` ДО раннего выхода «строка не изменилась», иначе гонка без подложки не открыла бы гейт вовсе).
- **Умерший observation не запирает гейт.** ⚠️ Round 4: `catch` каждого потока наблюдения снимает свой
  `*Loading` (с проверкой актуальности привязки), иначе сбой БД оставлял бы флаг `true` навсегда —
  карточка не показалась бы до перезапуска приложения, а ветка «нет взятий» осталась бы пустой без CTA.
  Ошибки — значения: показать чек-лист с предупреждением и CTA «обновить» лучше, чем не показать ничего.
- **`MarksEmptyLadder` и `marksEmptyState` удаляются полностью** (Task 6). Новый чек-лист их
  подменяет: «нет команды» → `blocked`-пункт `team`, «не привязаны чипы» → `blocked`-пункт `chips`,
  «готов» → свёрнутая зелёная строка. Подавление мигания переезжает в модель и ядро (см. ниже).
  Это осознанный отход от парности с Kotlin `MarksEmpty` — на iOS лестница и так была урезана (NFC-ветки
  выброшены), и держать мёртвый код ради зеркала смысла нет. Четыре теста `marksEmptyState_*` в
  `MarksDisplayTests.swift` удаляются, их покрытие переходит в `ReadinessChecklistTests`.

## Technical Details

### `Core/Readiness/ReadinessChecklist.swift`

```swift
enum ReadinessStatus { case done, warning, blocked }

enum ReadinessItemId { case team, chips, location, legend, map, clock, power }

enum ReadinessAction: Equatable {
    case chooseTeam, bindChips, requestLocation, openSettings, refresh, openMap
}

struct ReadinessItem: Equatable, Identifiable {
    let id: ReadinessItemId
    let status: ReadinessStatus
    let title: String
    let detail: String
    let action: ReadinessAction?
}

/// Доступность оффлайн-подложки для чек-листа (read-only срез `MapAvailability`).
enum MapReadiness { case notApplicable, missing, ready }

struct ReadinessInput {
    let hasTeam: Bool
    let teamTitle: String          // `Team.teamname` для detail; "" если нет
    let memberCount: Int
    let boundCount: Int
    let locationAuthorization: LocationAuthorization
    let isReducedAccuracy: Bool
    let checkpointCount: Int
    let map: MapReadiness
    let clock: ClockStatus
    let lowPowerMode: Bool
}

func readinessItems(_ input: ReadinessInput) -> [ReadinessItem]
```

Трёхзначный геостатус `enum LocationAuthorization { case notDetermined, denied, granted }` (в отличие от bool
`hasLocationAccess`) ⚠️ по итогам ревью (round 3) живёт **не** здесь, а в `kolco24/Core/Track/CurrentLocation.swift`:
его отдаёт `Location/CoreLocationTrackEngine.locationAuthorization()`, то есть это тип платформенной способности,
а не часть чек-листа, и `Location/` не должен зависеть от `Core/Readiness/` ради собственного возвращаемого типа.
В `ReadinessChecklist.swift` на его месте остался однострочный комментарий-указатель.

Правила формирования (все в этой функции, вьюха их не дублирует):

| Пункт | `done` когда | Иначе | Действие |
|-------|-------------|-------|----------|
| `team` | `hasTeam` | `blocked` | `.chooseTeam` |
| `chips` | `memberCount > 0 && boundCount >= memberCount` | `blocked`, detail «N из M»; `memberCount == 0` → `blocked` «Состав команды не загружен» | `.bindChips`; при `hasTeam == false` — `nil`; при пустом ростере — `.refresh` |
| `location` | `.granted && !isReducedAccuracy` | `warning`; `.notDetermined` → `.requestLocation`, `.denied` или reduced → `.openSettings` | см. слева |
| `legend` | `checkpointCount > 0` | `warning` | `.refresh` |
| `map` | `.ready` | `.missing` → `warning` + `.openMap`; `.notApplicable` → **пункт отсутствует в массиве** | `.openMap` |
| `clock` | `clock == .ok` | `warning` (`.noSync` и `.skewed` — разные detail) | `nil` |
| `power` | — | `lowPowerMode == false` → **пункт отсутствует**; `true` → `warning` | `nil` |

Пункты `chips` и `location` при `hasTeam == false` всё равно присутствуют (список стабильной длины
внутри одного состояния выбора), но `chips` тогда `blocked` с detail «сначала выберите команду» и
**без действия** — привязка до выбора команды тупиковая, CTA несёт строка `team`.

⚠️ Уточнено на ревью: пустой ростер (`memberCount == 0`) — тоже `blocked`, а не `done`:
`ScanModel.process` жёстко отбивает скан при пустом составе («команда не выбрана»), так что зелёная
галочка обещала бы невозможное; действие — `.refresh`. И у `power` действия нет: `app-settings:`
открывает страницу самого приложения, а Low Power Mode живёт в Настройках → Аккумулятор, публичного
URL туда у iOS нет — путь назван прямо в detail.

Производные для шапки считает **из самого массива** чистая `readinessSummary(_:) -> ReadinessSummary`
(`done`-счётчик, знаменатель `items.count` — не захардкоженная 7, скрытые пункты меняют длину, худший
статус, `allDone`). ⚠️ Уточнено на ревью: живёт в ядре, а не во вьюхе (это логика, а не вёрстка, и
покрывается таблицей); вьюхе остаётся только маппинг статуса в цвет.

### `AppEnvironment`

```swift
let isLowPowerMode: @Sendable () -> Bool
let locationAuthorization: @Sendable () -> LocationAuthorization
```

Прод-фабрика: `{ ProcessInfo.processInfo.isLowPowerModeEnabled }` и
`{ trackEngine.locationAuthorization() }`. Тестовый инициализатор: дефолты `{ false }` и
`{ .granted }`.

### `MarksModel`

```swift
private(set) var mapReadiness: MapReadiness = .notApplicable
private(set) var locationAuth: LocationAuthorization = .granted
private(set) var isReducedAccuracy: Bool = false
private(set) var lowPowerMode: Bool = false
// Гейт первой отрисовки (round 2): рядом с существующим `marksLoading`.
private(set) var bindingsLoading: Bool = false
private(set) var checkpointsLoading: Bool = false
private(set) var deviceStatePolled: Bool = false
private(set) var mapUrlResolved: Bool = false   // round 4: пятый (не-observation) сигнал гейта

func refreshDeviceState()      // синхронный опрос env: гео, точность, Low Power Mode, файл карты
                               // + безусловное перечитывание `mapUrl` из БД (см. ниже)
func requestLocationAccess()   // → env.requestLocationAuthorization() (AppModel.env приватен)
// Без гейта — прямой вход только для тестов, которым нужен массив без подавления.
func readiness(team: Team?, members: [TeamMemberItem], clock: ClockStatus) -> [ReadinessItem]
// Продовый вход: nil, пока `readinessCardVisible(...)` не пропустит все пять сигналов
// (marksLoading / bindingsLoading / checkpointsLoading / deviceStatePolled / mapUrlResolved).
func readinessCard(team: Team?, members: [TeamMemberItem], clock: ClockStatus) -> [ReadinessItem]?
```

Доступность карты считается из двух составляющих — `mapUrl` гонки и наличия файла подложки, — и **обе**
перечитываются на каждом опросе:

1. **`mapUrl` из БД** — задачей `mapUrlTask` (`loadMapUrl(_:)`), которая стартует и из
   `rebind(teamId:raceId:)`, и из `refreshDeviceState()`. В `rebind` — синхронный сброс `mapUrl = nil` и
   `mapReadiness = .notApplicable` до `await` (stale-guard), затем `raceStore.getById(raceId)`, проверка
   `!Task.isCancelled && boundRaceId == raceId`. Отмена в `deinit` рядом с остальными задачами.
   ⚠️ Уточнено на ревью (round 2): опрос перечитывает `mapUrl` **безусловно**, а не «пока он `nil`» —
   значение-гард сломался бы на `""` (сервер шлёт пустую строку как «карты нет»: она не `nil`, и опрос
   выключился бы навсегда) и не заметил бы отозванной/подменённой подложки. `loadMapUrl` нормализует `""` в
   `nil`, единственный гард — флаг `isLoadingMapUrl` (чтение уже в полёте), а пересчёт делается, только если
   строка гонки реально изменилась — иначе `FileManager` дёргался бы дважды за опрос.
2. **Наличие файла — при каждом `refreshDeviceState()`**: `mapUrl` пуст → `.notApplicable`, иначе
   `env.mapFileExists(raceId)` → `.ready` / `.missing`. Без этого пункт застревает в «не скачана»
   после возврата с вкладки «Карта» (см. Solution Overview).

### `MarksView` / `ReadinessCard`

```
┌────────────────────────────────────┐
│ ● ГОТОВНОСТЬ К СТАРТУ        4 / 6 │  mono(10,.bold), tracking 1.3
│ ████████████░░░░░░                 │  полоска 3pt
├────────────────────────────────────┤
│ ✓  Команда выбрана                 │  ink / detail — sub
│    Ф-мажор                         │
│ ✓  Чипы привязаны · 4 из 4         │
│ !  Геолокация                    › │  amber
│    Дана примерная локация          │
│ ✕  Карта не скачана              › │  brandRed
└────────────────────────────────────┘
```

Знаменатель — длина массива (здесь 6: карта есть, Low Power Mode выключен), не константа 7.

`Color.card` + `DS.cardRadius`, паддинги как у карточек `TeamView`. Цвет полоски и точки в шапке: есть
`blocked` → `brandRed`, иначе есть `warning` → `amber`, иначе `good`. Строка с `action` — `Button` в
стиле `MiscRowView` со стрелкой; без `action` — обычная строка. Все `done` → карточка сжимается в одну
зелёную строку «Всё готово к старту» + подсказка про приложение телефона к чипу.

`FloatingCTAView` не трогается. `NfcUnavailableStripView` остаётся отдельно, как сейчас.

## What Goes Where

- **Implementation Steps**: код, тесты, документация в этом репозитории.
- **Post-Completion**: проверки на живом устройстве (системные диалоги, Low Power Mode, реальный
  геостатус) — симулятор их не воспроизводит достоверно.

## Implementation Steps

### Task 1: Чистое ядро чек-листа

**Files:**
- Create: `kolco24/Core/Readiness/ReadinessChecklist.swift`
- Create: `kolco24Tests/Core/ReadinessChecklistTests.swift`

- [x] создать `kolco24/Core/Readiness/ReadinessChecklist.swift` с типами `ReadinessStatus`,
      `ReadinessItemId`, `ReadinessAction`, `ReadinessItem`, `MapReadiness`, `LocationAuthorization`,
      `ReadinessInput` (только `import Foundation`)
- [x] реализовать `readinessItems(_:) -> [ReadinessItem]` по таблице правил из Technical Details:
      фиксированный порядок, русские тексты в стиле существующих строк проекта
- [x] реализовать скрытие пунктов: `map == .notApplicable` и `lowPowerMode == false` не попадают в массив
- [x] написать тесты: нет команды → `team`/`chips` в `blocked`; 3 из 4 чипов → `chips` `blocked` с
      detail «3 из 4»; все привязаны → `chips` `done`
- [x] написать тесты геолокации: `.granted` + полная точность → `done`; `.notDetermined` → `warning` +
      `.requestLocation`; `.denied` → `warning` + `.openSettings`; `.granted` + reduced → `warning` +
      `.openSettings`
- [x] написать тесты скрытия: `map == .notApplicable` → нет пункта `map`; `lowPowerMode == false` →
      нет пункта `power`; `lowPowerMode == true` → есть, `warning`
- [x] написать тесты часов и легенды: `.ok` → `done`; `.noSync`/`.skewed` → `warning` с разными detail;
      `checkpointCount == 0` → `warning` + `.refresh`
- [x] написать тест «всё готово»: 7 пунктов при включённом Low Power Mode и карте `.ready`, все `done`
      кроме `power`; и 5 пунктов при `notApplicable` + выключенном Low Power Mode, все `done`
- [x] проверить grep-инвариант: в `Core/Readiness/` нет ничего кроме `Foundation`
- [x] прогнать тесты — зелено до Task 2

⚠️ По итогам ревью файл вырос против первоначального списка: добавлены `readinessSummary(_:)` /
`ReadinessSummary` (производные шапки — логика, а не вёрстка) и гейт первой отрисовки
`readinessCardVisible(...)`. `LocationAuthorization` наоборот уехал в `Core/Track/CurrentLocation.swift`
(это тип платформенной способности — см. Technical Details).

### Task 2: Трёхзначный геостатус в `CoreLocationTrackEngine`

**Files:**
- Modify: `kolco24/Location/CoreLocationTrackEngine.swift`

- [x] добавить `func locationAuthorization() -> LocationAuthorization` рядом с `hasLocationAccess()`
      (~строка 146), читающий `manager.authorizationStatus` с удерживаемого менеджера:
      `.notDetermined` → `.notDetermined`; `.authorizedWhenInUse`/`.authorizedAlways` → `.granted`;
      `.denied`/`.restricted`/default → `.denied`
- [x] **не удалять** `hasLocationAccess()` — его использует `TrackRecorder` для TOCTOU-проверки
- [x] дописать doc-комментарий в стиле соседних хелперов (почему менеджер удерживаемый, а не
      одноразовый в замыкании)
- [x] проверить grep-инвариант: `CoreLocation` по-прежнему только в `Location/`
- [x] тестов нет — платформенный адаптер device-only (конвенция проекта); поведение покрывается через
      чистый seam в Task 1 и через подмену замыкания в Task 4
- [x] собрать проект — зелено до Task 3

### Task 3: Новые инжекты в `AppEnvironment`

**Files:**
- Modify: `kolco24/App/AppEnvironment.swift`
- Create: `kolco24Tests/App/AppEnvironmentInjectsTests.swift`

- [x] добавить свойства `let isLowPowerMode: @Sendable () -> Bool` и
      `let locationAuthorization: @Sendable () -> LocationAuthorization` рядом с `hasLocationAccess`
      (~строки 147-152) с doc-комментариями
- [x] прокинуть в прод-фабрику (~строка 414): `{ ProcessInfo.processInfo.isLowPowerModeEnabled }` и
      `{ trackEngine.locationAuthorization() }`
- [x] добавить параметры в `private init` (`:175-183`) и **единственный** блок присваиваний (`:195-203`)
- [x] добавить параметры с дефолтами `{ false }` / `{ .granted }` в **отдельный** список `inMemory()`
      (`:442-450`) и в его проброс в `private init` (`:496-504`) — итого четыре места правки
- [x] проверить, что порядок конструирования графа не нарушен (leaseHolder → repos → syncCoordinator;
      adminSessionHolder → clients)
- [x] прогнать существующие тесты — ни один вызов `AppEnvironment` не должен сломаться
- [x] тесты — зелено до Task 4 (существующие вызовы `inMemory` не тронуты — Swift требует меток,
      позиционных вызовов в сюите нет; вместо правки `MarksModelTests` заведён отдельный
      `AppEnvironmentInjectsTests` на сам шов: дефолты + проброс + опрос)

### Task 4: Сбор сигналов в `MarksModel`

**Files:**
- Modify: `kolco24/App/MarksModel.swift`
- Create: `kolco24Tests/App/MarksModelReadinessTests.swift`

- [x] добавить `private(set) var mapReadiness: MapReadiness = .notApplicable` и
      `@ObservationIgnored private var mapReadinessTask: Task<Void, Never>?`; отмена в `deinit`
- [x] в `rebind(teamId:raceId:)` запустить чтение `mapUrl` со stale-guard: синхронный сброс `mapUrl`
      и `mapReadiness = .notApplicable` **до** `await`, `raceStore.getById(raceId)`, проверка
      `!Task.isCancelled && boundRaceId == raceId`, сохранение `mapUrl` в `@ObservationIgnored`-поле
      (образец — `MapModel.refreshAvailability`, `MapModel.swift:166`)
- [x] добавить `private(set) var locationAuth`, `isReducedAccuracy`, `lowPowerMode` и синхронный
      `func refreshDeviceState()`, опрашивающий замыкания `env`
- [x] **проверку наличия файла карты положить внутрь `refreshDeviceState()`**, а не только в `rebind`:
      `mapUrl` пуст → `.notApplicable`, иначе `env.mapFileExists(raceId)` → `.ready`/`.missing`.
      `rebind` рано выходит на неизменённой паре (`MarksModel.swift:70`), а вкладка живёт вечно —
      иначе пункт застрянет в «не скачана» после возврата с вкладки «Карта»
- [x] добавить `func requestLocationAccess()`, зовущий `env.requestLocationAuthorization()` —
      `AppModel.env` приватен (`AppModel.swift:64`), вьюха не может дотянуться иначе
- [x] добавить `func readiness(team:members:clock:) -> [ReadinessItem]`, собирающий `ReadinessInput` и
      вызывающий `readinessItems` (рядом с существующим `emptyState`)
- [x] обновить шапку-комментарий файла: новые сигналы и почему опрос, а не observation
- [x] написать тесты `mapReadiness` над `AppDatabase.makeInMemory()`: гонка с `mapUrl` и
      `mapFileExists == false` → `.missing`; та же с `true` → `.ready`; гонка без `mapUrl` →
      `.notApplicable`
- [x] написать тест stale-guard: после `rebind` на другую гонку `mapReadiness` сброшен синхронно, до
      первой эмиссии новой гонки
- [x] написать тест `refreshDeviceState`: подменённые замыкания `env` попадают в опубликованные
      свойства, а те — в `readiness(...)`
- [x] написать тест перечитывания карты: `mapFileExists` возвращает `false` → `.missing`; замыкание
      начинает возвращать `true` → после `refreshDeviceState()` (без `rebind`) стало `.ready`
- [x] проверить grep-инвариант: в `MarksModel.swift` только `Foundation` + `Observation`
- [x] прогнать тесты — зелено до Task 5

⚠️ Доработано на ревью (round 2–3), итоговое поведение отличается от формулировок выше:
чтение `mapUrl` вынесено в `loadMapUrl(_:)` и зовётся не только из `rebind`, но и из каждого
`refreshDeviceState()` **безусловно** (гард — только флаг `isLoadingMapUrl`), `""` нормализуется в `nil`,
а пересчёт `mapReadiness` делается лишь при реально изменившейся строке гонки; задача переименована
`mapReadinessTask` → `mapUrlTask`. Добавлены флаги `bindingsLoading`/`checkpointsLoading`/`deviceStatePolled`
и продовый вход `readinessCard(...)` поверх `readiness(...)` (гейт `readinessCardVisible`).

### Task 5: `ReadinessCard` в `MarksView` и проводка вкладки

**Files:**
- Modify: `kolco24/MarksView.swift`
- Modify: `kolco24/ContentView.swift`

- [x] добавить `var onOpenMap: () -> Void = {}` в `MarksView` рядом с `onChooseTeam`/`onBindChips`
- [x] в `ContentView` прокинуть `onOpenMap: { selectedTab = 2 }` по образцу
      `onBindChips: { selectedTab = 3 }` (`ContentView.swift:26`)
- [x] создать `private struct ReadinessCard: View`: шапка «ГОТОВНОСТЬ К СТАРТУ» `mono(10,.bold)`
      tracking 1.3 + счётчик «N / M» + полоска прогресса 3pt цветом `blocked → brandRed`,
      `warning → amber`, всё `done → good`
- [x] реализовать строку пункта в стиле `MiscRowView`: иконка статуса, title `ink`, detail `sub`,
      стрелка и `Button` только если есть `action`; выполненные пункты остаются видимыми,
      приглушёнными
- [x] реализовать свёрнутое состояние: все `done` → одна зелёная строка «Всё готово к старту» +
      подсказка про приложение телефона к чипу
- [x] заменить `MarksEmptyLadder` на `ReadinessCard` в ветке `tiles.isEmpty` (`MarksView.swift:437`),
      сохранив подавление мигания при `model?.marksLoading == true` (ничего не рисуем)
- [x] подключить действия: `.chooseTeam`/`.bindChips` → существующие замыкания; `.requestLocation` →
      `model?.requestLocationAccess()`; `.openSettings` → `@Environment(\.openURL)` +
      `URL(string: "app-settings:")` (**не** `UIApplication.openSettingsURLString` — образец
      `PhotoCaptureView.swift:224`, иначе ломается grep-инвариант «UIKit только в `DesignTokens` и
      `Audio/`»); `.refresh` → `Task { await appModel.refreshAll() }` (метод `async`,
      `AppModel.swift:622`); `.openMap` → `onOpenMap()`
- [x] вызвать `model?.refreshDeviceState()` из `.task`, из `onAppear` (возврат с вкладки «Карта» не
      меняет `scenePhase`) и из `onChange(of: scenePhase)` при `phase == .active` (`MarksView` уже
      наблюдает `scenePhase`: `@Environment` на строке 62, `onChange` на 112)
- [x] проверить, что `FloatingCTAView` и `NfcUnavailableStripView` не затронуты
- [x] обновить/добавить SwiftUI-превью карточки под `#if DEBUG` в стиле соседних превью файла
- [x] тестов на вьюху нет (конвенция проекта — UI-тестов нет; не автоматизируется); собрать проект и
      прогнать сюиту — зелено до Task 6

⚠️ Уточнено на ревью (round 2): подавления мигания в ветке вьюхи не осталось — вьюха вызывает
`model?.readinessCard(...)` и просто не рисует ничего на `nil`; условие живёт в модели и ядре.
Также `.refreshable` и действие `.refresh` доопрашивают устройство (`refreshDeviceState()` после
`refreshAll()`) — иначе pull-to-refresh не подхватывал изменившийся геостатус.

### Task 6: Удалить `MarksEmptyLadder` и `marksEmptyState`

**Files:**
- Modify: `kolco24/MarksView.swift`
- Modify: `kolco24/Core/Marks/MarksDisplay.swift`
- Modify: `kolco24/App/MarksModel.swift`
- Modify: `kolco24Tests/Core/MarksDisplayTests.swift`
- Modify: `kolco24Tests/App/MarksModelTests.swift`

- [x] удалить `private struct MarksEmptyLadder` из `MarksView.swift` (~строка 539)
- [x] удалить `enum MarksEmptyState` и `func marksEmptyState` из `MarksDisplay.swift` (строки 202-227)
      вместе с абзацем шапки-комментария про урезанный порт `MarksEmpty`
- [x] удалить `func emptyState(hasTeam:members:)` из `MarksModel.swift` (~строка 206) и упоминание
      лестницы в шапке-комментарии файла
- [x] **не удалять** `MarksModel.boundCount(members:)` — у него свои `BoundCountTests` и он нужен
      чек-листу
- [x] удалить четыре теста `marksEmptyState_*` из `MarksDisplayTests.swift` (строки 324-344, вместе с
      заголовком `// MARK: - БОНУС-тесты`) и соответствующую строку из шапки-комментария файла — их
      покрытие перешло в `ReadinessChecklistTests` (Task 1)
- [x] **перенести, а не выбросить, три интеграционных случая из
      `kolco24Tests/App/MarksModelTests.swift`** (вызовы `model.emptyState(...)` на строках 155, 169,
      174, 176, 188, 193, 194): «нет команды», «не все чипы привязаны», «подавление до первой эмиссии»
      переписываются на `model.readiness(team:members:clock:)` и переезжают в
      `MarksModelReadinessTests.swift`. Чистая таблица `ReadinessChecklistTests` их **не** заменяет —
      там нет реальной БД. Без этого шага тестовая цель не компилируется
- [x] проверить `grep -rn "MarksEmptyState\|marksEmptyState\|MarksEmptyLadder"` — пусто
- [x] прогнать тесты — зелено до Task 7

### Task 7: Verify acceptance criteria

- [x] все семь пунктов из таблицы Overview реализованы и показываются (`readinessItems` строит
      `team`/`chips`/`location`/`legend`/`map`/`clock`/`power`; `MarksView.swift:478-489` рендерит)
- [x] пункт карты отсутствует на гонке без `mapUrl`; пункт энергосбережения отсутствует при
      выключенном Low Power Mode (`mapItem`/`powerItem` возвращают `nil`; тесты
      `noMapUrl_hidesMapItem`, `lowPowerModeOff_hidesPowerItem`)
- [x] чек-лист исчезает после первого взятия КП (`tiles.isEmpty == false`) и не мигает на холодном
      старте — ветка `MarksView.swift:478`, гейт из пяти сигналов в `readinessCardVisible(...)`,
      вьюха просто не рисует ничего на `readinessCard(...) == nil` (`:482`)
- [x] порядок пунктов не меняется при смене статусов (сортировок нет ни в ядре, ни во вьюхе; тест
      `orderIsStableRegardlessOfStatuses`)
- [x] `blocked` только у `team` и `chips` (четыре вхождения `status: .blocked` — все в
      `teamItem`/`chipsItem`; тест `blockedOnlyForTeamAndChips`)
- [x] grep-инварианты целы (прогнаны буквально):
      `grep -rn "import" kolco24/Core/Readiness/` → одна строка `import Foundation`;
      `grep -rn "^import" kolco24/App/MarksModel.swift` → `Foundation`, `Observation`;
      `grep -rn "^import CoreLocation" kolco24/` → только `Location/` (3 файла).
      [deviation] исходная формулировка `grep -rln "CoreLocation"` даёт ещё 7 файлов, но это
      **комментарии/имена типов**, а не импорты (так было и до плана); проверен реальный
      инвариант — строка импорта;
      `grep -rln "import UIKit" kolco24/` → ровно `DesignTokens.swift` и `Audio/ScanFeedbackPlayer.swift`;
      `grep -rn "UIApplication" kolco24/` → пусто
- [x] полная сборка: `** BUILD SUCCEEDED **` (destination по UDID — форма `name=iPhone 16`
      неоднозначна на машине, фоллбэк санкционирован `CLAUDE.md`)
- [x] полная сюита: `** TEST SUCCEEDED **`
- [x] e2e-тестов в проекте нет — пропускаем осознанно (не автоматизируется)

### Task 8: [Final] Update documentation

- [x] дописать `kolco24/Core/` в `CLAUDE.md` группу `Readiness` (чек-лист готовности) в списке
      концернов; `CLAUDE.md` держим компактным — детали остаются в этом плане
- [x] добавить в `CLAUDE.md` в «Known facts, not bugs» строку: уведомления на iOS не нужны для
      фонового трека (`UIBackgroundModes: location` + `CLBackgroundActivitySession`) — чтобы вопрос
      не всплывал заново
- [x] отметить в `CLAUDE.md` («Removed features stay removed»), что лестница `MarksEmpty` заменена
      чек-листом готовности и возврату не подлежит
- [ ] переместить план в `docs/plans/completed/`
- [ ] открыть PR (внешнее действие — подтверждает пользователь)

## Post-Completion

*Требует ручных действий — чекбоксов нет.*

**Ручная проверка на устройстве** (симулятор не воспроизводит достоверно):

- свежая установка: тап по пункту «Геолокация» при `.notDetermined` показывает системный диалог, а не
  выбрасывает в Настройки
- после отказа в геодоступе тот же пункт ведёт в Настройки iOS и возвращается с обновлённым статусом
  (проверка опроса на `scenePhase == .active`)
- выдача «Примерная геопозиция» (Settings → Privacy → Location → Precise Location off) → пункт в
  `warning` с правильным detail
- включение Low Power Mode на живом устройстве → пункт появляется без перезапуска приложения
- гонка без `mapUrl` → пункта карты нет; гонка с `mapUrl` → тап ведёт на вкладку «Карта», где
  скачивание работает как прежде
- визуальная проверка карточки в светлой и тёмной теме

**Внешние системы:** не затронуты — серверный контракт не меняется, новых эндпоинтов нет.
