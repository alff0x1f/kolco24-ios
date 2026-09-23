# «До КВ» на вкладке Отметки: контрольное время, отсчёт, время на дистанции

## Overview

Ячейка «До КВ» в `MetricsCard` (`kolco24/MarksView.swift:549`) — заглушка `"—"`. Задача — показать
в ней живое состояние контрольного времени (КВ) команды:

- до старта — КВ категории («КВ 8:00»);
- после своей отметки на КП типа `start` — обратный отсчёт («До КВ 3:27»);
- КВ вышло, финиша нет — опоздание красным («Опоздание +0:12»);
- после своей отметки на КП типа `finish` — время на дистанции («Время 7:48», красным при опоздании).

Сервер уже отдаёт `control_time` (минуты, `0` = не задано) в `categories[]` ответа
`GET /app/race/<id>/teams/` (`~/src/kolco24/src/apps/mobile/serializers.py` `CategorySerializer`,
`_TEAMS_SCHEMA_VERSION = 2`). iOS поле игнорирует — его нужно протащить DTO → модель → БД.

**Вне скоупа (сознательно):**
- `overtime_penalty` и расчёт штрафа в баллах — YAGNI.
- `team.startTime/finishTime` (судейские сканы с сервера) — источник только свои отметки команды.
- Сброс ETag teams в миграции — приложение не в проде; тестовые устройства переустановить.

## Context (from discovery)

- DTO: `kolco24/Net/Dto/TeamsResponse.swift` `CategoryDto` (`id, code, short_name, name, order`).
- Модель: `kolco24/Model/Category.swift` (memberwise init, вызывается в `TeamRepository` и тестах
  `TeamPickerLogicTests`, `TeamPickerModelTests`, `TeamModelTests`, `SimpleStoresTests`).
- GRDB: `kolco24/Data/Records/Category+GRDB.swift`; схема `kolco24/Data/AppDatabase.swift`
  (`v1` = Room v5, `v2` = `races.mapUrl` — образец для `v3`).
- Маппинг: `kolco24/Data/Repositories/TeamRepository.swift` `CategoryDto.toCategory(raceId:)`.
- Модель вкладки: `kolco24/App/MarksModel.swift` (`marks`, `checkpoints`, `rebind` со stale-guard).
  Образец подписки на категории: `kolco24/App/TeamModel.swift:135` (`env.teamStore.observeCategoriesForRace`).
- Время отметки: `trustedTakenAt ?? takenAt` (как `MarksDisplay`, `PhotoTarget`, `MapModel`).
- Тип КП: `Checkpoint.type` ∈ `start|finish|test|kp` (из легенды).
- Часы: `ClockStatus` (`.noSync | .ok | .skewed(skewMs)`, `skew = wall − trusted`) в `AppModel.clockStatus`.
- Сервер считает опоздание так (`~/src/kolco24/src/apps/race/results.py:135-144`):
  `duration_min = int(ms/1000/60)`, опоздание если `duration_min > control_time`.
- Тесты: `kolco24Tests/Net/DtoDecodingTests.swift`, `kolco24Tests/Data/AppDatabaseSchemaTests.swift`
  (колонки + сценарий апгрейда `v1 → конец` для `mapUrl`), `kolco24Tests/Data/Repositories/`,
  `kolco24Tests/App/MarksModelTests.swift`, `kolco24Tests/Core/MarkMetricsTests.swift`.

## Development Approach

- **testing approach**: Regular (код, затем тесты в той же задаче)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change
- соблюдать инварианты CLAUDE.md: `Core/` и `App/` — только Foundation/Observation; `import GRDB`
  только в `Data/`; реальные сторы над `AppDatabase.makeInMemory()`, без фейков БД

## Testing Strategy

- **unit tests**: Swift Testing, на каждую задачу
- **e2e tests**: в проекте нет UI e2e; вьюха проверяется вручную (см. Post-Completion)
- команда: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'`

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Solution Overview

Вариант A из брейншторма: чистая функция в `Core/Marks/ControlTime.swift` считает состояние по
отметкам, легенде, КВ и «сейчас». `MarksModel` только собирает входы (отметки, легенда, категория
команды). Вьюха тикает раз в минуту через `TimelineView(.everyMinute)` и форматирует состояние.
Никаких таймеров в модели.

Ключевые решения:
- **Источник старта/финиша — только свои отметки.** Работает офлайн, сразу после скана.
- **Старт** = самая ранняя отметка на КП типа `start` (полнота состава не важна).
  **Финиш** = самая ранняя отметка на КП типа `finish` с временем ≥ старта.
- **Округление вниз везде**, как на сервере. Опоздание 0:59 штрафа не даёт.
- **«Сейчас»** = `context.date` тика `TimelineView` в ms минус `skewMs` при `.skewed`, иначе без
  поправки — чтобы вычитать из trusted-времени старта время в той же шкале (`skew = wall − trusted`).
  Известный край: старт, взятый до первой синхры (`trustedTakenAt == nil`), — в wall-шкале; если
  потом часы станут `.skewed`, отсчёт сдвинется на skew. Редко, не лечим.

## Technical Details

### Данные

- `CategoryDto.controlTime: Int?` (`control_time`). Optional — ответ без ключа декодируется.
- `Category.controlTime: Int` (минуты, `0` = не задано). Явный `init` с `controlTime: Int = 0`,
  чтобы существующие вызовы не менялись.
- Маппинг: `controlTime: controlTime ?? 0`.
- Миграция `v3`: `ALTER TABLE categories ADD COLUMN controlTime INTEGER` — nullable, **без SQL-DEFAULT**
  (инвариант схемы «дефолты в Swift, не в DDL», `AppDatabaseSchemaTests:249`; образец — v2 `mapUrl`).
  `Category+GRDB.init(row:)` читает `row["controlTime"] ?? 0`; `encode` пишет `controlTime`.

### Ядро

```swift
enum ControlTimeState: Equatable {
    case unknown                                   // КВ не задано / нет категории
    case notStarted(limitMs: Int64)
    case running(remainingMs: Int64)
    case overtime(overMs: Int64)
    case finished(elapsedMs: Int64, overMs: Int64?)
}

func controlTimeState(
    marks: [Mark], checkpoints: [Checkpoint], controlMinutes: Int, nowMs: Int64
) -> ControlTimeState
```

Алгоритм:
1. `typeById = checkpoints` → `[id: type]`; время отметки `t(m) = m.trustedTakenAt ?? m.takenAt`.
2. `start = min t(m)` среди отметок с типом `start`. `finish = min t(m)` среди `finish` с `t ≥ start`.
3. `limitMs = controlMinutes * 60_000`.
4. Есть `start` и `finish`: `elapsed = finish − start`. `overMs = controlMinutes > 0 &&
   elapsed / 60_000 > controlMinutes ? elapsed − limitMs : nil` → `.finished(elapsed, overMs)`.
5. `controlMinutes <= 0` → `.unknown`.
6. Нет `start` → `.notStarted(limitMs)`.
7. `elapsed = nowMs − start`. `elapsed < limitMs` → `.running(limitMs − elapsed)`,
   иначе `.overtime(elapsed − limitMs)`.

Без легенды типы неизвестны → старта нет → `.notStarted` / `.unknown`.

### Отображение (`MetricView`, формат `Ч:ММ`, минуты вниз)

| Состояние | Подпись | Значение | Цвет |
|---|---|---|---|
| unknown | До КВ | — | ink |
| notStarted | КВ | 8:00 | ink |
| running | До КВ | 3:27 | ink |
| overtime | Опоздание | +0:12 | brandRed |
| finished, `overMs == nil` | Время | 7:48 | ink |
| finished, `overMs != nil` | Время | 8:12 | brandRed |

Первую минуту после КВ показывается «Опоздание +0:00» красным — предупреждение, штрафа ещё нет.
Форматтер `formatHoursMinutes(_ ms: Int64) -> String` — чистая функция в том же `ControlTime.swift`.

## What Goes Where

- **Implementation Steps**: код, тесты, CLAUDE.md в этом репо.
- **Post-Completion**: ручная проверка на устройстве, переустановка на тест-устройствах.

## Implementation Steps

### Task 1: Протащить `control_time` в DTO, модель и БД

**Files:**
- Modify: `kolco24/Net/Dto/TeamsResponse.swift`
- Modify: `kolco24/Model/Category.swift`
- Modify: `kolco24/Data/Records/Category+GRDB.swift`
- Modify: `kolco24/Data/AppDatabase.swift`
- Modify: `kolco24/Data/Repositories/TeamRepository.swift`
- Modify: `kolco24Tests/Net/DtoDecodingTests.swift`
- Modify: `kolco24Tests/Data/AppDatabaseSchemaTests.swift`
- Modify: `kolco24Tests/Data/SimpleStoresTests.swift`
- Modify: `kolco24Tests/Data/Repositories/TeamRepositoryTests.swift`
- Modify: `kolco24/Model/Race.swift` (комментарий «первая iOS-only колонка … v2»)

- [x] `CategoryDto`: `let controlTime: Int?` + `CodingKeys` `controlTime = "control_time"`
- [x] `Category`: `let controlTime: Int` + явный `init` с дефолтом `controlTime: Int = 0` (как `Team.swift`); в шапке — серверное поле сверх Room v5 (минуты, `0` = не задано)
- [x] `Category+GRDB`: читать `row["controlTime"] ?? 0`, писать `controlTime`
- [x] `AppDatabase`: миграция `v3` — `ALTER TABLE categories ADD COLUMN controlTime INTEGER` (nullable, без DEFAULT); обновить устаревшие «до v2»-комментарии (`AppDatabase.swift:6-11`, `:93`, `:303-306`)
- [x] `TeamRepository.toCategory`: `controlTime: controlTime ?? 0`
- [x] тест декодирования `CategoryDto`: с `control_time: 480` и без ключа (→ `nil`)
- [x] `AppDatabaseSchemaTests`: `Col("controlTime", "INTEGER", notNull: false)` в `categories`; `applied == ["v1","v2","v3"]` (`:214`, `:274`); шапка теста
- [x] новый тест апгрейда по образцу `migrationV1ToV2AddsMapUrlAndPreservesRows`: мигрировать `upTo: "v2"`, вставить категорию сырым SQL, догнать — строка жива, читается с `controlTime == 0`
- [x] `TeamRepositoryTests`: фикстура с `control_time` → `controlTime`; без ключа → `0`
- [x] `SimpleStoresTests:354`: round-trip `Category` с `controlTime`
- [x] run tests - must pass before task 2

### Task 2: Чистая функция `controlTimeState` и форматтер

**Files:**
- Create: `kolco24/Core/Marks/ControlTime.swift`
- Create: `kolco24Tests/Core/ControlTimeTests.swift`

- [x] `enum ControlTimeState` и `func controlTimeState(marks:checkpoints:controlMinutes:nowMs:)` по алгоритму из Technical Details
- [x] `func formatHoursMinutes(_ ms: Int64) -> String` (`Ч:ММ`, минуты вниз, отрицательные не ожидаются)
- [x] тесты состояний: `unknown` (`controlMinutes == 0`), `notStarted`, `running`, `overtime`, `finished` с опозданием и без
- [x] тесты правил: две отметки старта → ранняя; финиш раньше старта игнорируется; финиш без старта → `notStarted`; `trustedTakenAt` важнее `takenAt`; без легенды → `notStarted`
- [x] тесты округления: опоздание 59 с на финише → `overMs == nil`; ровно 60 с → `overMs != nil`; `finished` при `controlMinutes == 0` → `overMs == nil`
- [x] тесты `formatHoursMinutes`: `0` → `0:00`, `59_999` → `0:00`, `8 ч` → `8:00`, `3 ч 27 мин 59 с` → `3:27`
- [x] run tests - must pass before task 3

### Task 3: Категории в `MarksModel`

**Files:**
- Modify: `kolco24/App/MarksModel.swift`
- Modify: `kolco24Tests/App/MarksModelTests.swift`

- [x] `private(set) var categories: [Category] = []` + `categoriesTask`; подписка `env.teamStore.observeCategoriesForRace(raceId)` в `rebind`
- [x] stale-guard: в `rebind` отменить `categoriesTask` и очистить `categories` до новой подписки; в цикле перепроверять `self.boundRaceId == raceId` (как `checkpointsTask`); `categoriesTask?.cancel()` в `deinit`
- [x] `func controlState(team: Team?, nowMs: Int64) -> ControlTimeState` (другое имя — иначе метод затеняет функцию `Core`) — берёт `controlTime` категории `team.categoryId` (нет → `0`) и зовёт функцию из `Core`
- [x] тест: категория с `controlTime` в in-memory БД + отметка старта → `.running`
- [x] тест: команда без категории → `.unknown`; rebind на другую гонку очищает `categories`
- [x] run tests - must pass before task 4

### Task 4: UI ячейки «До КВ»

**Files:**
- Modify: `kolco24/MarksView.swift`

- [x] `MetricsCard`: новые параметры `controlState: (Int64) -> ControlTimeState` и `clock: ClockStatus`; убрать комментарий-заглушку
- [x] ячейка в `TimelineView(.everyMinute) { context in … }`: `nowMs = context.date ms − skewMs` при `.skewed`, иначе без поправки
- [x] подпись/значение по таблице из Technical Details; красный — существующим `MetricView(isWarning:)` (brandRed + mono-шрифт), новых параметров не добавлять
- [x] в `marksScreen` передать `{ model?.controlState(team: team, nowMs: $0) ?? .unknown }` и `appModel.clockStatus`
- [x] сборка проходит; логика уже покрыта тестами задач 2–3 (вьюхи в проекте не тестируются)
- [x] run tests - must pass before task 5

### Task 5: Verify acceptance criteria

- [ ] все состояния из Overview реализованы
- [ ] инварианты: `grep -rn "import GRDB" kolco24/Core kolco24/App kolco24/Model` пусто; `ControlTime.swift` — только Foundation
- [ ] полный прогон: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'`
- [ ] сборка: `xcodebuild -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16' build`

### Task 6: [Final] Update documentation

- [ ] CLAUDE.md: коротко — `AppDatabase` миграции (`v3` = `categories.controlTime`), `Core/Marks` упоминает ControlTime; компактно, без деталей стадии
- [ ] `Model/Race.swift:17`: комментарий про iOS-only колонки учитывает `v3`
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification:**
- на тест-устройствах переустановить приложение (иначе сохранённый ETag teams даст `304` и `controlTime` останется `0`)
- выставить категории `control_time` в админке, проверить «КВ 8:00» до старта
- взять КП-старт → «До КВ» с отсчётом, обновление раз в минуту
- с маленьким КВ (1–2 мин) дождаться «Опоздание +0:00» красным, затем «+0:01». `.everyMinute` тикает на границах
  минут по стенным часам, не от старта — смена может запаздывать до ~1 мин, это не баг
- взять КП-финиш → «Время» (красным, если опоздание ≥ 1 мин)
- проверить светлую и тёмную темы
