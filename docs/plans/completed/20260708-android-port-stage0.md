# Этап 0 портирования: инфраструктура проекта

Детализация этапа 0 из [android-port.md](../android-port.md).

## Overview

Подготовить iOS-проект к переносу логики из Android-приложения (`kolco24_app_v2`):
- секреты API (`API_BASE_URL`, `APP_KEY_ID`, `APP_SECRET`, `LOCAL_API_BASE_URL`) вне git, по аналогии с `local.properties`;
- зависимость GRDB (SQLite, аналог Room) через SPM;
- ATS-исключение для cleartext HTTP до LAN-сервера гонки;
- смоук-тесты, фиксирующие, что инфраструктура работает.

После этапа проект собирается только с заполненным `Secrets.xcconfig` (громкий отказ при отсутствии, как merge gate в Android), код читает секреты через `enum Secrets`, а этап 1 (чистая логика) начинается с чистого листа.

## Context (from discovery)

- `kolco24.xcodeproj`: Info.plist генерируется (`GENERATE_INFOPLIST_FILE = YES`), `.xcconfig`-файлов нет, SPM-зависимостей нет, deployment target iOS 18.0.
- Тестовый таргет `kolco24Tests` уже существует, Swift Testing (пустой шаблон) — создавать не надо.
- Android-референс: секреты из `local.properties` (`kolco24.*`) с env-фолбэком `KOLCO24_*`, сборка падает при отсутствии; cleartext разрешён только для `192.168.1.5` (`network_security_config.xml`).

## Development Approach

- **testing approach**: Regular (конфигурация → код → смоук-тесты)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
- **CRITICAL: all tests must pass before starting next task**
- **CRITICAL: update this plan file when scope changes during implementation**

## Testing Strategy

- **unit tests**: Swift Testing в существующем `kolco24Tests`; смоук-тесты на `Secrets` и линковку GRDB. Задачи 1–2 — чистая конфигурация без Swift-кода, их тесты появляются в задаче 3 (`SecretsTests` проверяет результат всей цепочки xcconfig → Info.plist → Bundle).
- **e2e**: нет (UI-тесты этапа 0 не требуются).
- негативная проверка сборки без `Secrets.xcconfig` — вручную в задаче 5 (не автоматизируется в unit-тестах).

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview

**Секреты: `.xcconfig` → Info.plist → `Bundle.main`.**
Как base configuration к Debug/Release app-таргета подключается **закоммиченный** `Config/App.xcconfig`, который делает необязательный `#include "Secrets.xcconfig"` (сам `Secrets.xcconfig` — в `.gitignore`). Missing `baseConfigurationReference` — это лишь warning, сборка продолжится с пустыми переменными; а вот отсутствующий non-optional `#include` — жёсткая ошибка «could not find included file» — «громкий отказ» без скриптов-валидаторов. Значения через `$(VAR)` подставляются в кастомные ключи Info.plist, код читает их через `Bundle.main`.

Замечание про безопасность: кастомные ключи Info.plist лежат в собранном `.app` открытым текстом, `APP_SECRET` извлекаем из IPA. Это паритет с Android (`BuildConfig`-поля так же извлекаемы из APK) — осознанное свойство, не защищённое хранилище.

**Info.plist: частичный файл + генерация.**
Создаём `kolco24/Info.plist` и указываем в `INFOPLIST_FILE`, `GENERATE_INFOPLIST_FILE` остаётся `YES` — Xcode сливает файл с генерируемыми ключами, переносить текущую генерацию не нужно. В файле только 4 кастомных ключа и ATS.

**ATS: `NSAllowsLocalNetworking = YES`.**
Точечный пиннинг IP как в Android невозможен — `NSExceptionDomains` не принимает IP-адреса. `NSAllowsLocalNetworking` разрешает незащищённые соединения только внутри локальной сети; облачный API остаётся HTTPS-only. Смена IP LAN-сервера не потребует пересборки (шире андроидного пиннинга — осознанно).

**GRDB:** SPM-пакет `https://github.com/groue/GRDB.swift`, 7.x up-to-next-major, линк только к app-таргету (тесты видят через host application). Код с GRDB на этом этапе не пишем — только зависимость и смоук.

## Technical Details

`Config/App.xcconfig` (в git, подключается к таргету):

```
// Жёсткий гейт: без Secrets.xcconfig сборка падает с
// "could not find included file". Скопируй Secrets.example.xcconfig.
#include "Secrets.xcconfig"
```

`Config/Secrets.xcconfig` (гоча: `//` в URL — начало комментария в xcconfig, нужен трюк `$()`; сломанный трюк обрезает значение до `https:` — это ловит проверка `url.host` в тестах):

```
API_BASE_URL = https:/$()/api.kolco24.ru
APP_KEY_ID = ios-app-1
APP_SECRET = <hex>
LOCAL_API_BASE_URL = http:/$()/192.168.1.5
```

`kolco24/Info.plist` — соответствие ключей:

| Info.plist key | xcconfig var |
|---|---|
| `Kolco24APIBaseURL` | `$(API_BASE_URL)` |
| `Kolco24AppKeyId` | `$(APP_KEY_ID)` |
| `Kolco24AppSecret` | `$(APP_SECRET)` |
| `Kolco24LocalAPIBaseURL` | `$(LOCAL_API_BASE_URL)` |

плюс `NSAppTransportSecurity` → `NSAllowsLocalNetworking = YES`.

`Secrets.swift`: `enum Secrets` со статическими свойствами из `Bundle.main.infoDictionary`; пустое/отсутствующее значение → `fatalError` с внятным сообщением (ловит «xcconfig есть, но ключ забыли заполнить»; работает и в unit-тестах — они хостятся в приложении). Нюанс: при пустом значении `fatalError` уронит тестовый процесс раньше, чем сработает assert «непустое» в `SecretsTests` — это приемлемо, отказ всё равно громкий; основной гейт — build-time `#include`.

CI-фолбэк (аналог env-переменных Android): xcconfig не умеет читать env; когда появится CI — шаг, генерирующий `Secrets.xcconfig` из `KOLCO24_*` перед сборкой. Сейчас не настраиваем (CI нет).

## Implementation Steps

### Task 1: Файлы секретов и .gitignore

**Files:**
- Create: `Config/App.xcconfig`
- Create: `Config/Secrets.xcconfig`
- Create: `Config/Secrets.example.xcconfig`
- Modify: `.gitignore` (существует, пустой)

- [x] создать `Config/App.xcconfig` (в git) с non-optional `#include "Secrets.xcconfig"` и комментарием про гейт
- [x] создать `Config/Secrets.example.xcconfig` с плейсхолдерами, `$()`-трюком и комментарием «скопируй в Secrets.xcconfig и заполни»
- [x] создать `Config/Secrets.xcconfig` с реальными значениями (боевые значения взять из `kolco24_app_v2/local.properties`; `LOCAL_API_BASE_URL = http://192.168.1.5` — из `network_security_config.xml`, в `local.properties` его нет)
- [x] добавить `Config/Secrets.xcconfig` в `.gitignore`
- [x] проверить: `git status` не показывает `Secrets.xcconfig`, показывает `App.xcconfig` и example
- [x] тесты: нет Swift-кода в этой задаче — проверка цепочки целиком в `SecretsTests` (Task 3)

### Task 2: Подключение xcconfig и частичный Info.plist

**Files:**
- Create: `kolco24/Info.plist`
- Modify: `kolco24.xcodeproj/project.pbxproj`

- [x] создать `kolco24/Info.plist` с 4 кастомными ключами `Kolco24*` = `$(VAR)` и `NSAppTransportSecurity` → `NSAllowsLocalNetworking = YES`
- [x] в pbxproj: добавить file reference на `Config/App.xcconfig`, `Config/Secrets.example.xcconfig` и `kolco24/Info.plist` (xcconfig-и — PBXFileReference в новой группе `Config/`; `Info.plist` лежит в synchronized-группе `kolco24`, поэтому вместо отдельного reference — `PBXFileSystemSynchronizedBuildFileExceptionSet` с `membershipExceptions = (Info.plist)`, чтобы файл не копировался как ресурс)
- [x] в pbxproj: выставить `baseConfigurationReference` на `App.xcconfig` для Debug/Release конфигураций app-таргета (не тестовых)
- [x] в pbxproj: `INFOPLIST_FILE = kolco24/Info.plist` для app-таргета, `GENERATE_INFOPLIST_FILE` оставить `YES`
- [x] собрать: `xcodebuild -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16' build` — успех (destination по имени флачит на этой машине — собрано по `id=<UDID>` симулятора iPhone 16)
- [x] проверить продукт сборки: `plutil -p <DerivedData>/.../kolco24.app/Info.plist` — значения подставлены (не `$(...)`), `NSAllowsLocalNetworking` присутствует, генерируемые ключи на месте (`UIApplicationSceneManifest` и особенно `NFCReaderUsageDescription` — он нужен приложению уже сейчас)
- [x] тесты: нет Swift-кода — проверка в `SecretsTests` (Task 3); существующий набор `kolco24Tests` прогнан — зелёный

### Task 3: Secrets.swift + SecretsTests

**Files:**
- Create: `kolco24/Secrets.swift`
- Create: `kolco24Tests/SecretsTests.swift`

- [x] создать `enum Secrets` со свойствами `apiBaseURL`, `appKeyId`, `appSecret`, `localAPIBaseURL`, читающими `Bundle.main`; отсутствие/пустота → `fatalError` с именем ключа и подсказкой про `Config/Secrets.xcconfig`
- [x] написать `SecretsTests` (Swift Testing): все 4 значения непустые и не содержат `$(`
- [x] написать тесты URL-ов: `URL(string:)` не nil; схема `https` у `apiBaseURL`, `http` у `localAPIBaseURL`; **`url.host` непустой у обоих** — именно host ловит сломанный `$()`-трюк (обрезанное `https:` парсится как валидный URL со схемой, но без host)
- [x] прогнать тесты: `xcodebuild test ... -only-testing:kolco24Tests` — зелёные (5 тестов, по `id=<UDID>` симулятора iPhone 16)

### Task 4: Зависимость GRDB + смоук-тест

**Files:**
- Modify: `kolco24.xcodeproj/project.pbxproj` (+ `Package.resolved`)
- Create: `kolco24Tests/GRDBSmokeTests.swift`

- [x] добавить SPM-пакет `https://github.com/groue/GRDB.swift`, up-to-next-major от 7.0.0, слинковать с app-таргетом (только с ним) — резолвится в 7.11.1, `Package.resolved` закоммичен
- [x] написать смоук-тест: `import GRDB`, открыть in-memory `DatabaseQueue`, выполнить тривиальный запрос (`GRDBSmokeTests`: тривиальный SELECT + create/insert/count)
- [x] ⚠️ фолбэк: если `import GRDB` в тестовом таргете не компилируется (видимость через host app — известно хрупкое место SPM), добавить продукт GRDB также в зависимости `kolco24Tests` — не потребовался, `import GRDB` в тестах компилируется через host app
- [x] прогнать тесты — зелёные (7 тестов, `-only-testing:kolco24Tests` по `id=<UDID>` симулятора iPhone 16)

### Task 5: Verify acceptance criteria

- [x] `xcodebuild build` проходит с заполненным `Secrets.xcconfig` (BUILD SUCCEEDED, `id=<UDID>` симулятора iPhone 16)
- [x] негативная проверка: временно переименовать `Config/Secrets.xcconfig` → сборка падает с ошибкой «could not find included file 'Secrets.xcconfig'» (missing `baseConfigurationReference` дал бы лишь warning — потому гейт через `#include` в `App.xcconfig`); вернуть файл (BUILD FAILED с ожидаемой ошибкой в `Config/App.xcconfig:6`, файл возвращён и проверен)
- [x] `xcodebuild test` — весь набор зелёный (TEST SUCCEEDED: 7 unit-тестов + UI-тесты)
- [x] `plutil -p` по продукту сборки: значения подставлены, `NSAllowsLocalNetworking = 1` (все 4 ключа `Kolco24*` без `$(...)`, `NSAllowsLocalNetworking => true`, генерируемые ключи на месте — `NFCReaderUsageDescription`, `UIApplicationSceneManifest`)
- [x] приложение запускается в симуляторе (UI не изменился) — установлено и запущено через `simctl`, процесс жив после запуска; визуальная проверка «UI не изменился» — ручная (не автоматизируется)

### Task 6: [Final] Документация

**Files:**
- Modify: `docs/plans/android-port.md`
- Modify: `CLAUDE.md`

- [x] в `android-port.md` пометить этап 0 ссылкой на этот план
- [x] в `CLAUDE.md` добавить раздел про сборку с нуля: скопировать `Config/Secrets.example.xcconfig` → `Config/Secrets.xcconfig`, заполнить; упомянуть `Secrets.swift`, ATS и GRDB
- [x] переместить этот план в `docs/plans/completed/` (ссылка в шапке исправлена на `../android-port.md`)

## Post-Completion

**Manual verification:**
- когда появится сетевой код (этап 3): подписанный GET `/app/races/` до облака (HTTPS) и до LAN-сервера (cleartext, проверка `NSAllowsLocalNetworking` на реальном устройстве в одной сети с сервером).

**External system updates:**
- CI (когда появится): шаг генерации `Config/Secrets.xcconfig` из env-переменных `KOLCO24_*` перед сборкой.
