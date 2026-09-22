# Запись кодов на браслеты участников (раздел «Администратор»)

## Overview

Сейчас на чип КП пишется серверный код (формат `K24`, тип `0x1`), а браслет участника опознаётся
только по NFC UID через пул `member_tags`. UID легко подделать. Задача — записывать на браслет
серверный секретный код (тот же формат `K24`, тип `CHIP_TYPE_PARTICIPANT = 0x2`), по аналогии с
провижинингом КП.

Новый экран «Записать браслет участника» в секции «Чипы» админки. Два режима в одном флоу:
- UID браслета уже есть в локальном пуле `member_tags` → номер известен, сервер просто отдаёт код;
- UID не в пуле (или сервер ответил `404`) → админ вводит номер (с автоинкрементом), сервер создаёт
  привязку и отдаёт код.

Флоу двухтаповый, как у КП: тап 1 — UID → запрос → `code`; тап 2 — тот же UID → запись
(header-last) + read-back.

«Проверить чип участника» дополнительно показывает, записан ли на браслет код.

**Вне скоупа (сознательно):**
- **Бэкенд.** Эндпоинта нет, серверный `Tag` (`~/src/kolco24/src/website/models/tag.py`) без поля
  `code`. Делается отдельной задачей в репо бэкенда по контракту ниже. iOS идёт первым — как
  `marks`/`judge_scans`. До деплоя любой запрос получает `404` (экран просит номер, затем показывает
  ошибку) — ожидаемо.
- **Использование кода браслета в отметках и судейских сканах** (`present[].code`, `judge_scans`) —
  отдельная задача. Там браслет по-прежнему идентифицируется по UID.
- **Оффлайн-запись с предзагрузкой кодов** — отклонено (секреты на телефоне, новые браслеты всё равно
  требуют сети).

## Context (from discovery)

- Формат чипа: `kolco24/Core/Nfc/ChipRecord.swift` — `buildChipRecord(type:code:)` уже принимает тип;
  `parseChipRecord(pages:)` принимает **только** `CHIP_TYPE_KP`; `writeRecord` делает read-back через
  `readRecord` → `parseChipRecord` (KP-only). `CHIP_TYPE_PARTICIPANT = 0x2` объявлен, не используется.
- Образец хоста: `kolco24/App/ProvisioningModel.swift` + `kolco24/Core/Admin/ProvisioningLogic.swift`
  + `kolco24/ProvisioningView.swift` (двухтаповый флоу, `ProvisioningScanning.setPendingWrite`,
  `ScanLiveness`, `successHoldMs`, `closeRequested` на 401).
- Образец пула: `kolco24/App/MemberChipCheckModel.swift` (null-sentinel `pool == nil`,
  `memberTagStore.observeForRace`).
- Сеть: `ApiClient.bindTag` (`kolco24/Net/ApiClient.swift:~288`), DTO `kolco24/Net/Dto/TagBind.swift`;
  замыкание `env.bindTag` в `kolco24/App/AppEnvironment.swift:68,319`; фабрика
  `AppModel.makeProvisioningModel` (`kolco24/App/AppModel.swift:494`).
- Сканер: `kolco24/Nfc/NfcChipScanner.swift` `defaultProcess` (стр. ~166) — при совпавшем pending-UID
  пишет, иначе `readRecord`. `TagReading` — `kolco24/Core/Scan/ChipScanning.swift`.
- Навигация: `kolco24/AdminFlowView.swift` — `AdminRoute`, секция «Чипы», хост-обёртки
  `…HostView` с `.task { model = appModel.make…() }`.
- Тесты: `kolco24Tests/Core/ChipRecordTests.swift`, `kolco24Tests/Core/ProvisioningLogicTests.swift`,
  `kolco24Tests/App/ProvisioningModelTests.swift` (там `FakeProvisioningScanner`),
  `kolco24Tests/Net/ApiClientTests.swift` + `FakeTransport`,
  `kolco24Tests/Core/MemberChipCheckLogicTests.swift`.
- Stage-доки: `docs/plans/completed/20260712-android-port-stage10.md` (админка, провижининг),
  `docs/plans/completed/20260710-android-port-stage5.md` (NFC).

## Development Approach

- **testing approach**: Regular (код, затем тесты в той же задаче)
- complete each task fully before moving to the next
- make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- run tests after each change
- maintain backward compatibility (ридеры КП, отметки и судейские сканы ведут себя как раньше)
- работа в ветке (не `main`), итог — PR

## Testing Strategy

- **unit tests**: Swift Testing, реальные сторы на `AppDatabase.makeInMemory()`, фейки только для сети
  (`FakeTransport`, замыкание `bindMemberTag`) и NFC (`FakeProvisioningScanner`, фейковый
  `NfcTransport`). DB не фейкается.
- **e2e/UI tests**: в проекте нет. SwiftUI-вью и `NfcChipScanner` — device-only, покрываются через
  чистые швы (Core + модель).
- Гейт: зелёный локальный suite + сборка. Живой `200` не требуется (эндпоинт не задеплоен).

Команды:
```bash
xcodebuild test -project kolco24.xcodeproj -scheme kolco24 \
  -destination 'platform=iOS Simulator,name=iPhone 16'
xcodebuild test ... -only-testing:kolco24Tests/<SuiteName>
```

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Solution Overview

Подход A: отдельный экран и отдельная хост-модель `MemberProvisioningModel` по образцу
`ProvisioningModel`. `ProvisioningModel` не трогаем. Дублирование хост-логики (~150 строк стейт-машины)
выбрано осознанно: у режимов разные источники цели (список КП против пула/номера), разные эндпоинты,
счётчики и строки — общая абстракция связала бы две стабильные модели через `if mode`.

Переиспользуется всё ниже хоста: формат `K24` (`buildChipRecord`/`writeRecord`), прод-сканер
`NfcChipScanner` как `ProvisioningScanning` (pending-write не меняется — он пишет готовую `record`),
`ScanLiveness`, `ScanFeedbackPlaying`, `PostResult`, `AdminAuthRepository.onUnauthorized`.

Ключевая правка Core — типизированный разбор записи: без неё read-back в `writeRecord` отклоняет
тип `0x2`, и запись браслета всегда `failed`.

## Technical Details

### API-контракт (для бэкенда и для iOS)

`POST /app/race/<raceId>/member_tags/` — cloud-клиент, подпись `X-App-*` + админский Bearer,
**без ретраев** (как `bindTag`), путь с завершающим слэшем.

Запрос:
```json
{"nfc_uid": "04A1B2C3D4E5F6", "number": 101}
{"nfc_uid": "04A1B2C3D4E5F6", "number": null}
```
`number` кодируется всегда, `null` — явным JSON `null` (kotlinx-стиль, ручной `encode(to:)`).

Ответы:
| Статус | Смысл | `PostResult` | UI |
|---|---|---|---|
| `201` | создан новый Tag | `.success(resp)` | → запись |
| `200` | Tag уже был (идемпотентно, тот же код) | `.success(resp)` | → запись |
| `404` | `number == null`, UID неизвестен | `.error(404)` | → `needsNumber` |
| `409` | UID привязан к **другому** номеру | `.conflict` | «Браслет уже привязан к другому участнику» |
| `400/401/403/429/offline` | как у КП | — | строки `provisionErrorMessage`; 401 → закрыть экран |

Тело ответа: `{"number": 101, "nfc_uid": "04A1B2C3D4E5F6", "code": "<32 hex>"}`. Сервер генерирует
`code` один раз и хранит (как `ensure_code` у КП); повтор отдаёт тот же код.

У одного номера может быть несколько браслетов (`Tag.number` не уникален — запасной браслет): новый
UID с уже занятым номером → `201`, не `409`. `409` — только когда **этот UID** уже привязан к другому
номеру.

### Формат чипа

- `parseChipRecord(pages:type:) -> Data?` — магик + версия + **заданный** тип.
- `parseChipRecord(pages:)` → `parseChipRecord(pages:, type: CHIP_TYPE_KP)` (без изменения поведения).
- `readRecordPages(_:) -> Data?` — сырые 20 байт стр. 4..8 (FAST_READ, фолбэк на 2×READ); логика
  выносится из текущего `readRecord` без изменений.
- `readRecord(_:)` = `readRecordPages` + parse KP (поведение прежнее). Типизированного `readRecord`
  не вводим — вызыватели берут `readRecordPages` + `parseChipRecord(pages:type:)`.
- `writeRecord`: read-back через `readRecordPages` +
  `parseChipRecord(pages:, type: Int([UInt8](record)[3] & 0x0F))` (через `[UInt8]`, как в текущем коде —
  `Data` может иметь ненулевой `startIndex`).

### Состояние экрана

```swift
enum MemberProvisionState: Equatable {
    case waitingForChip
    case needsNumber(uid: String)
    case binding(uid: String, number: Int?)
    case waitingForWrite(uid: String, number: Int)
    case success(number: Int)
    case failed(reason: String)
}
```

«UID известен» = UID есть в пуле **или** в `freshFeed` этой сессии (пул не обновится до следующего
refresh `member_tags`; повтор с `number: null` сервер отдаёт как `200`).

Переходы (хост):
- `waitingForChip`/`failed` + тап → UID известен ? `binding(uid, nil)` : `needsNumber(uid)`
- `needsNumber(uid)` + тап **другого** браслета → та же ветка, что из `waitingForChip` (проверка
  «известен»); тап того же UID → игнор
- `needsNumber` + `confirmNumber(n)` → `binding(uid, n)`. Guard: только в `.needsNumber` и `n >= 1`,
  иначе no-op. Текст поля парсит чистая `parseMemberNumber(String) -> Int?` (пусто/0/не-число/
  переполнение → `nil`)
- `cancel()` из `needsNumber`/`waitingForWrite`/`failed` → `clearPendingWrite`, отмена
  `bindTask`/`advanceTask`, `writeHint = nil`, `waitingForChip`. Во вью — кнопка «Отмена»
- `binding` → `.success` → `waitingForWrite(uid, resp.number)` + `setPendingWrite`
- `binding(uid, nil)` → `.error(404)` → `needsNumber(uid)`
- `binding` → `.unauthorized` → `onUnauthorized()` + `closeRequested`
- `binding` → прочее → `failed(memberProvisionErrorMessage)`
- `waitingForWrite` + тап: чужой UID → hint «Приложите тот же браслет»; свой + `.success` →
  `success(number)`, `nextNumber = number + 1`, свежий браслет в ленту, через `successHoldMs` →
  `waitingForChip`; свой + не-success → hint «Не удалось записать, приложите снова», pending сохранён
- `binding`/`success` + тап → игнор
- любой тап до первой эмиссии пула → игнор (null-sentinel)

`nextNumber: Int?` — стартует `nil` (поле пустое), после успешной записи = `number + 1`.
`freshFeed: [FreshBracelet]` (`struct FreshBracelet: Equatable, Identifiable { uid, number }`), новые
сверху, кап `feedCap = 20`. Дедуп по UID: повтор того же UID заменяет запись (номер из ответа) и
поднимает её наверх.

### Проверка браслета

`TagReading` получает `memberCode: Data?` (дефолт `nil` в `init` — существующие вызовы не меняются).
`NfcChipScanner.defaultProcess`: `pages = readRecordPages(t)` один раз → `code = parse(KP)`,
`memberCode = code == nil ? parse(PARTICIPANT) : nil`. Лишнего transceive нет.
`MemberChipCheckModel.FeedItem` получает `hasCode: Bool`, модель — `private(set) var lastHasCode: Bool`
(статус-панель вью читает `lastResult`, а не ленту). Вью показывает «код записан» / «без кода» для `.ok`
и в панели, и в строках «Недавние». `classifyMemberChipCheck` не меняется.

## What Goes Where

- **Implementation Steps**: iOS-код, тесты, CLAUDE.md, stage-док.
- **Post-Completion**: бэкенд-эндпоинт, проверка на устройстве.

## Implementation Steps

### Task 1: Типизированный разбор записи K24

**Files:**
- Modify: `kolco24/Core/Nfc/ChipRecord.swift`
- Modify: `kolco24Tests/Core/ChipRecordTests.swift`

- [x] добавить `parseChipRecord(pages:type:)`; `parseChipRecord(pages:)` сделать обёрткой с `CHIP_TYPE_KP`
- [x] вынести чтение сырых страниц в `readRecordPages(_:)`; `readRecord(_:)` поверх него (поведение прежнее)
- [x] `writeRecord`: read-back с типом из заголовка записи (`Int([UInt8](record)[3] & 0x0F)`)
- [x] обновить комментарии: `CHIP_TYPE_KP` («единственное записываемое»), `CHIP_TYPE_PARTICIPANT`, doc `parseChipRecord`, шапку файла
- [x] тесты: разбор типа `0x2` с `type: PARTICIPANT` → код; с `type: KP` → `nil`; регрессия — `parseChipRecord(pages:)` отклоняет `0x2`
- [x] тесты: `writeRecord` записи участника на фейковом транспорте → `.success`; KP-запись по-прежнему `.success` (`writeRecord_writesHeaderLast_andSucceeds`); тип в read-back не совпал с заголовком → `.failed`; `readRecordPages` фолбэк на 2×READ
- [x] прогнать `ChipRecordTests` — зелёные

### Task 2: DTO и `ApiClient.bindMemberTag`

**Files:**
- Create: `kolco24/Net/Dto/MemberTagBind.swift`
- Modify: `kolco24/Net/ApiClient.swift`
- Modify: `kolco24Tests/Net/ApiClientTests.swift`
- Create: `kolco24Tests/Net/MemberTagBindDtoTests.swift`

- [x] `MemberTagBindRequest(nfcUid, number: Int?)` с ручным `encode(to:)` — `number` всегда, `null` явно; `MemberTagBindResponse(number, nfcUid, code)`
- [x] `ApiClient.bindMemberTag(raceId:nfcUid:number:)` → `POST /app/race/<id>/member_tags/` через `post` (по образцу `bindTag`)
- [x] тесты DTO: ключи `nfc_uid`/`number`, явный `null`, декодирование ответа
- [x] тесты ApiClient: путь со слэшем, метод POST, 201/200 → `.success`, 404 → `.error(404)`, 409 → `.conflict`, 403 без ретрая (один запрос)
- [x] прогнать тесты — зелёные

### Task 3: Чистая логика `MemberProvisioningLogic`

**Files:**
- Create: `kolco24/Core/Admin/MemberProvisioningLogic.swift`
- Create: `kolco24Tests/Core/MemberProvisioningLogicTests.swift`

- [ ] `enum MemberProvisionState` (см. Technical Details)
- [ ] `memberProvisionErrorMessage(_:)`: 409 → «Браслет уже привязан к другому участнику»; 404 (доходит сюда только
  при запросе с номером) → «Не найдено на сервере»; остальное делегирует `provisionErrorMessage`
- [ ] `parseMemberNumber(_ text: String) -> Int?` — пусто/`0`/не-число/переполнение → `nil`, ведущие нули допустимы
- [ ] тесты на каждую ветку маппера строк и `parseMemberNumber`
- [ ] прогнать тесты — зелёные

### Task 4: Хост-модель `MemberProvisioningModel` + проводка в граф

**Files:**
- Create: `kolco24/App/MemberProvisioningModel.swift`
- Modify: `kolco24/App/AppEnvironment.swift`
- Modify: `kolco24/App/AppModel.swift`
- Create: `kolco24Tests/App/MemberProvisioningModelTests.swift`

- [ ] модель по форме `ProvisioningModel`: `liveness`, `start(scanner:)`/`attachProductionScanner`/`beginScanning`/`stop`, `deinit`
- [ ] наблюдение пула `memberTagStore.observeForRace` с null-sentinel
- [ ] `processReading` + `confirmNumber(_:)` (guard `.needsNumber`, `n >= 1`) + `cancel()` + переходы из Technical Details; «известен» = пул ∪ `freshFeed`; bind в неструктурированном `Task`, захват замыкания `bindMemberTag` (§6), результат отбрасывается при `Task.isCancelled`
- [ ] успех: `buildChipRecord(type: CHIP_TYPE_PARTICIPANT, …)` → `setPendingWrite`; после записи — `clearPendingWrite`, `nextNumber`, `FreshBracelet` в ленту, `successHoldMs` → `waitingForChip`, фидбек `.success` + фанфары
- [ ] `env.bindMemberTag: (Int, String, Int?) async -> PostResult<MemberTagBindResponse>` в `AppEnvironment`; фабрика `AppModel.makeMemberProvisioningModel()` с прод `NfcChipScanner`
- [ ] тест-хелперы: своя копия `FakeProvisioningScanner`/`RecordingFeedback` (в `ProvisioningModelTests` они вложенные) + новый `MemberBindStub` под `(Int, String, Int?)`; пул сидится через `env.memberTagStore.insertAll` (как `ChipCheckModelTests`)
- [ ] тесты: UID в пуле → запрос с `nil` → `waitingForWrite` → тап 2 → `success`, `clearPendingWrite`, `nextNumber == number + 1`, после hold → `waitingForChip`
- [ ] тесты: UID не в пуле → `needsNumber` → `confirmNumber(7)` → запрос с `7`; `404` на `nil` → `needsNumber`; `404` с номером → «Не найдено на сервере»
- [ ] тесты: `needsNumber` + тап UID из пула → `binding(uid, nil)`; тап того же UID → игнор; повторный тап браслета, записанного в этой сессии → `binding(uid, nil)`
- [ ] тесты: `confirmNumber` вне `needsNumber` и с `0` → no-op; `cancel()` из `waitingForWrite` → `clearPendingWrite` + `waitingForChip`
- [ ] тесты: `409` → `failed`; `401` → `onUnauthorized` вызван + `closeRequested`; неверный hex → «Неверный код от сервера»; `stop()` во время `binding` → поздний результат не меняет состояние
- [ ] тесты: чужой UID на тапе 2 → hint, без `success`; неудачная запись → pending сохранён, повтор успешен
- [ ] тесты: скан до первой эмиссии пула игнорируется; `setPendingWrite` получил запись с типом `0x2`; дедуп ленты (повтор UID → замена + наверх)
- [ ] прогнать тесты — зелёные

### Task 5: Экран и пункт меню админки

**Files:**
- Create: `kolco24/MemberProvisioningView.swift`
- Modify: `kolco24/AdminFlowView.swift`

- [ ] `AdminRoute.memberProvisioning`, пункт в секции «Чипы»: «Записать браслет участника» / «Запись кода на браслет»
- [ ] хост-обёртка `…HostView` по образцу provisioning (`.task { model = appModel.makeMemberProvisioningModel() }`, `stop()` на уходе, дисмисс по `closeRequested`)
- [ ] `MemberProvisioningView`: зона скана (стили `ProvisioningView`), в `needsNumber` — поле номера `.numberPad` (префилл `nextNumber`, парсинг через `parseMemberNumber`, кнопка «Привязать» неактивна при `nil`), кнопка «Отмена» в `needsNumber`/`waitingForWrite`, лента пилюль «№101 · A1B2»; `#Preview` с фейком
- [ ] сборка проходит; существующие тесты зелёные (вью без unit-тестов — device-only)

### Task 6: «Проверить чип участника» показывает наличие кода

**Files:**
- Modify: `kolco24/Core/Scan/ChipScanning.swift`
- Modify: `kolco24/Nfc/NfcChipScanner.swift`
- Modify: `kolco24/App/MemberChipCheckModel.swift`
- Modify: `kolco24/CheckMemberChipView.swift`
- Modify: `kolco24Tests/App/ChipCheckModelTests.swift` (там живут `memberCheck_*` и `FakeChipScanner`)

- [ ] `TagReading.memberCode: Data?` (дефолт `nil` в `init`); обновить doc `TagReading` («не-K24 = браслет»)
- [ ] `NfcChipScanner.defaultProcess`: один `readRecordPages`, два разбора (KP, затем PARTICIPANT при `code == nil`)
- [ ] `MemberChipCheckModel`: `FeedItem.hasCode` + `lastHasCode`; обновить шапку («браслет не несёт K24-кода»)
- [ ] `CheckMemberChipView` — «код записан» / «без кода» для `.ok` в статус-панели и в строках «Недавние»
- [ ] тесты (`memberCheck_*`): `ok` + `memberCode` → `hasCode`/`lastHasCode == true`; `ok` без кода → `false`; `kpChip`/`unknown` не меняются
- [ ] прогнать тесты — зелёные

### Task 7: Verify acceptance criteria

- [ ] оба режима (пул / ввод номера) и 404-фолбэк реализованы
- [ ] запись браслета проходит read-back (тип `0x2`); ридеры КП, отметки и судейские сканы не изменились
- [ ] grep-инварианты: нет `import GRDB`/`SwiftUI`/`CoreNFC` в `Core/`, `App/`, `Net/`
- [ ] полный suite: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'`
- [ ] сборка: `xcodebuild … build`

### Task 8: [Final] Update documentation

- [ ] CLAUDE.md: `POST …/member_tags/` в список «Backend endpoints not yet deployed»; `Core/Admin` — упомянуть запись браслетов (кратко, файл остаётся компактным)
- [ ] переместить этот план в `docs/plans/completed/`

## Post-Completion

*Items requiring manual intervention or external systems - no checkboxes, informational only*

**Бэкенд (`~/src/kolco24`, отдельная задача):**
- поле `code` (16 байт) у `Tag` + генерация один раз (аналог `ensure_code` у КП)
- `POST /app/race/<id>/member_tags/` по контракту выше (админ-права, 201/200/404/409)
- сдвиг ETag `member_tags` при создании/изменении Tag (уже покрыто `member_tags_version`, проверить)
- решить, отдавать ли `code` в `GET member_tags` — **нет** (секрет не должен уходить всем клиентам)

**Ручная проверка на устройстве (после деплоя бэкенда):**
- браслет из пула: тап → тап → «№N записан»; «Проверить чип участника» → «код записан»
- новый браслет: тап → ввод номера → «Привязать» → тап → успех; номер +1 в поле
- браслет, привязанный к другому номеру → текст про 409
- записанный браслет при взятии КП определяется как браслет (отметка засчитывается)
- прерванный тап 2 (убрать чип) → повтор записывает корректно
