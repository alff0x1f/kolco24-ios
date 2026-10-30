# Офлайн-выдача браслетов участников: iOS (K24 v2, HMAC-код гонки)

## Overview

- Сейчас судья привязывает браслет только онлайн (`POST member_tags/bind/` выдаёт случайный `code`), а
  приложение участника и судейская станция старт/финиш узнают номер по UID из скачанного пула `member_tags`.
  Если заготовленные браслеты закончились и нет интернета, выдать новый браслет нельзя.
- Новый формат **v2**: номер и `race_id` лежат на чипе открыто, `code` считает судейский телефон —
  `HMAC-SHA256(K_race, 0x22 ‖ uid ‖ race_id ‖ number)[:12]`. Ключ гонки судья скачивает заранее из облака
  (`GET /app/race/<id>/member_key/`). Привязки уходят на сервер из очереди, когда появится сеть.
- Приложение участника и судейская станция берут номер браслета v2 прямо с чипа, без пула. Участник шлёт `code`
  в отметках. Ключа у участника нет, код он не проверяет — сервер ставит `MarkPresent.code_ok`, подмена выясняется
  на финише.
- Парные планы: `server/docs/plans/20261020-offline-member-bracelets.md` (выкатывается первым),
  `android-kolco24/docs/plans/20261020-offline-member-bracelets.md` (зеркало этого плана).

## Context (from discovery)

- `kolco24/Core/Nfc/ChipRecord.swift` — формат `K24` (сборка/разбор, `decodeTagPages` → `(code, memberCode)`,
  guard перед записью, `readRecordPages` FAST_READ `3A 04 08` + запасной 2×READ).
- `kolco24/Nfc/NfcChipScanner.swift:196` — одно чтение страниц, разбор в оба типа → `TagReading`
  (`kolco24/Core/Scan/ChipScanning.swift:44`, поля `code`, `memberCode`, `readFailed`).
- Читатели `TagReading.memberCode`: `kolco24/App/ProvisioningModel.swift:312`, `kolco24/App/MemberChipCheckModel.swift:161`,
  `kolco24/Core/Admin/JudgeScanLogic.swift` (в комментарии), `kolco24/App/MemberProvisioningModel.swift`;
  тесты `ChipRecordTests`, `ChipCheckModelTests`, `ProvisioningModelTests` строят `memberCode:`.
- `kolco24/Core/Admin/MemberProvisioningLogic.swift` + `kolco24/App/MemberProvisioningModel.swift` +
  `kolco24/MemberProvisioningView.swift` — судейская выдача (сетевой bind, номер по `404`, повторная запись).
- `kolco24/Core/Admin/JudgeScanLogic.swift` — `memberNumber` только из пула, `poolReady` проверяется первым;
  `kolco24/App/JudgeScanModel.swift`.
- `kolco24/Net/ApiClient.swift:317` — `bindMemberTag`; `kolco24/Net/Dto/MemberTagBind.swift`;
  `kolco24/App/AppEnvironment.swift:613` — `adminRoute(raceId:)` (облако/LAN на тап).
- `kolco24/Keychain/AdminTokenStoreKeychain.swift`, `kolco24/Core/Stores/AdminTokenStore.swift` — образец хранения секрета.
- `kolco24/Data/Repositories/JudgeScanUploadRepository.swift` + `kolco24/Data/Stores/JudgeScanStore.swift` — образец очереди.
- Привязка у участника: `kolco24/App/TeamModel.swift:361` `processBind` — при пустом пуле сначала `hasBeenSynced`/
  инлайн-refresh, иначе `.poolNotReady` (`:371-384`); `kolco24/Core/Team/BindDecision.swift`, `kolco24/BindChipSheet.swift`.
- `kolco24/App/ScanModel.swift:507` — `MarkMemberSnapshot(numberInTeam, nfcUid, number)` без `code`;
  `MarkStore.swift:81` — `code` в снапшоте уже поддержан.
- `kolco24/Data/AppDatabase.swift` — GRDB-миграции, последняя `v4`. CryptoKit уже используется в `Core/`
  (`Core/Api/Signing.swift`, `Core/Crypto/LegendCrypto.swift`).

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
- maintain backward compatibility: браслеты v1 и пул `member_tags` работают как раньше
- задачи участника (1–4) идут раньше судейских (5–8): после Task 4 приложение можно выпускать
- работа в ветке (не `main`)

## Testing Strategy

- **unit tests**: `kolco24Tests/` — `Core/*` (чистая логика), `App/*Model*` (модели с `FakeChipScanner`),
  `Data/*` (GRDB-сторы и схема на `AppDatabase.makeInMemory()`), `Net/*` (DTO).
- **общий тестовый вектор** (одинаковый в трёх репо): ключ `000102…1f` (32 байта), UID `04A1B2C3D4E5F6`,
  `race_id` 42, номер 123 → `code` = `deb887a736ce08d1fd704d62`, запись = `4b323422002a007bdeb887a736ce08d1fd704d62`.
- Команда: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'`
  (отдельный класс — `-only-testing:kolco24Tests/<Class>`).

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope
- keep plan in sync with actual work done

## Solution Overview

- **Формат** живёт в `ChipRecord.swift` рядом с v1: та же длина и тот же FAST_READ. `decodeTagPages` и `TagReading`
  вместо `memberCode: Data?` получают `member: MemberRecord?` — `.v1(code)` или `.v2(raceId, number, code)`.
- **Участник**: номер браслета v2 этой гонки — с чипа, пул и сеть не нужны; v1 — из пула. `code` читается с чипа при
  каждом скане на КП и уходит в снапшоте отметки. Сканер уже читает страницы браслета, новый I/O не нужен. В привязке
  `code` не храним.
- **Судейская станция старт/финиш**: v2 этой гонки даёт номер с чипа, v1 — пул.
- **Судья** не ходит в сеть при выдаче: ключ гонки в Keychain, `code` считается локально (CryptoKit `HMAC<SHA256>`),
  запись на чип, затем привязка в очередь `pending_member_binds`.
- **Ключ** скачивается только из облака: LAN-сервер ключ не создаёт.
- **Очередь** уходит по `adminRoute(raceId:)` на момент отправки и удаляется после первого `200`/`201`. Сверка LAN → облако
  после гонки — задача сервера.
- **Выкатка без проверки версии**: сначала выпуск с Tasks 1–4, судейская запись v2 (Tasks 5–8) — следующим выпуском.

## Technical Details

Запись v2 (страницы 4–8):

```
стр. 4    'K' '2' '4' 0x22          ← version=2, type=0x2
стр. 5    race_id u16 BE, number u16 BE
стр. 6–8  code = HMAC-SHA256(K_race, 0x22 ‖ uid_bytes ‖ race_id u16 BE ‖ number u16 BE)[:12]
```

- `0x22` — байт версии/типа со стр. 4, первым байтом сообщения: разделение доменов с будущими
  типами чипов под тем же ключом гонки.
- `uid_bytes` — сырые байты UID (`NFCMiFareTag.identifier`), не hex-строка.
- `memberCode(...)` возвращает `nil` вне `1...65535` — без `precondition` (ошибки — значения); номер судьи валидируется
  в логике выдачи (не больше 65535).
- `code` на проводе — 24 hex (v2), 32 hex (v1); hex — через `Core/Util/HexBytes`.

Номер браслета у участника и на станции (`resolveBraceletNumber`):

| На чипе | Результат |
|---|---|
| v2, `race_id` = выбранная гонка | номер с чипа |
| v2, другая гонка | «Браслет с другой гонки» |
| v1 / пусто / чужой / `readFailed` | номер из пула, иначе «нет в пуле» |
| КП | «Это чип КП» |

Решение судьи по тапу:

| На чипе | Действие |
|---|---|
| пусто / чужой | спросить номер |
| v2 этой гонки, HMAC верный (ключ есть у судьи) | «Уже записан №N», предложить перезаписать |
| v2 этой гонки, HMAC неверный | «Подделка: код не совпал», предложить перезаписать |
| v1 / v2 другой гонки | спросить номер, предзаполнить из пула (если UID там есть) |
| КП | отказ |

Очередь привязок — исходы `POST bind/`:

| Ответ | Действие |
|---|---|
| `200` / `201` | удалить строку |
| `400` / `409` | записать `error`, строка остаётся (⚠ в ленте, кнопка «Убрать») |
| `401` / `403` / `429` / `5xx` / сеть | оставить строку без ошибки, прервать проход |

## What Goes Where

- **Implementation Steps**: формат, HMAC, привязка у участника, `code` в отметках, станция старт/финиш, ключ в Keychain,
  очередь, судейская логика/модель/экран, GRDB-миграция, тесты, документация.
- **Post-Completion**: проверка на реальных браслетах, выкатка в порядке сервер → участник → судья.

## Implementation Steps

### Task 1: Формат v2, `MemberRecord` и `memberCode` в `Core/Nfc`

**Files:**
- Modify: `kolco24/Core/Nfc/ChipRecord.swift`
- Create: `kolco24/Core/Nfc/MemberCode.swift`
- Modify: `kolco24/Core/Scan/ChipScanning.swift`
- Modify: `kolco24/Nfc/NfcChipScanner.swift`
- Modify: `kolco24/App/ProvisioningModel.swift`
- Modify: `kolco24/App/MemberChipCheckModel.swift`
- Modify: `kolco24/App/MemberProvisioningModel.swift`
- Modify: `kolco24Tests/Core/ChipRecordTests.swift`
- Create: `kolco24Tests/Core/MemberCodeTests.swift`
- Modify: `kolco24Tests/App/ChipCheckModelTests.swift`
- Modify: `kolco24Tests/App/ProvisioningModelTests.swift`

- [ ] `memberCode(key:uid:raceId:number:) -> Data?` (12 байт, CryptoKit; `nil` вне диапазона)
- [ ] `enum MemberRecord { case v1(Data), v2(raceId: Int, number: Int, code: Data) }`; сборка v2 и разбор в `decodeTagPages`
- [ ] `TagReading.memberCode` → `member: MemberRecord?`; перевести всех читателей на `member != nil` (v1 и v2 — «браслет
      участника»); в проверке браслета показывать номер и гонку v2
- [ ] guard перед записью: v1 ↔ v2 участника разрешено, КП ↔ участник запрещено
- [ ] тесты: общий вектор (`code` и 20 байт), сборка/разбор v2, неизвестная версия → `nil`, v1 разбирается,
      `memberCode` вне диапазона → `nil`, guard для всех пар
- [ ] обновить `ChipCheckModelTests`, `ProvisioningModelTests` под `member:`
- [ ] run tests - must pass before task 2

### Task 2: Привязка браслета у участника

**Files:**
- Modify: `kolco24/Core/Team/BindDecision.swift`
- Modify: `kolco24/App/TeamModel.swift`
- Modify: `kolco24/BindChipSheet.swift`
- Modify: `kolco24/Localizable.xcstrings`
- Modify: `kolco24Tests/Core/BindChipDecisionTests.swift`
- Modify: `kolco24Tests/App/TeamModelTests.swift`

- [ ] чистая `resolveBraceletNumber(member:isKp:raceId:poolNumber:)` по таблице из Technical Details; `decideBind`
      получает готовый номер
- [ ] `TeamModel.processBind` (`:371-384`): для v2 этой гонки решать сразу, без проверки/обновления пула
- [ ] новые исходы `otherRace` и `kpChip` в `BindChipSheet`; строки — в `Localizable.xcstrings` (ru + en)
- [ ] тесты `resolveBraceletNumber` (все строки таблицы), `decideBind` с новыми исходами, `TeamModel` с v2-браслетом
      при пустом несинхронизированном пуле → успех без refresh
- [ ] run tests - must pass before task 3

### Task 3: `code` браслета в отметках

**Files:**
- Modify: `kolco24/App/ScanModel.swift`
- Modify: `kolco24Tests/App/ScanModelTests.swift`
- Modify: `kolco24Tests/Net/MarkUploadDtoTests.swift`

- [ ] в `ScanModel` (`:507`) класть в `MarkMemberSnapshot` `code` из `reading.member` (hex) и `number`
      (v2 этой гонки — с чипа, иначе `chipNumbers`)
- [ ] `readFailed` при известном UID → `code = nil`, отметка не теряется
- [ ] тесты: снапшот с v1-кодом, с v2-кодом, без кода; `present[].code` в DTO
- [ ] run tests - must pass before task 4

### Task 4: Судейская станция старт/финиш читает номер v2

**Files:**
- Modify: `kolco24/Core/Admin/JudgeScanLogic.swift`
- Modify: `kolco24/App/JudgeScanModel.swift`
- Modify: `kolco24/Localizable.xcstrings`
- Modify: `kolco24Tests/Core/JudgeScanLogicTests.swift`
- Modify: `kolco24Tests/App/JudgeScanModelTests.swift`

- [ ] логика получает `member: MemberRecord?` и `raceId`: v2 этой гонки → `participant_number` с чипа, даже при
      неготовом пуле или UID не в пуле; v2 другой гонки → отказ «Браслет с другой гонки»; v1 — как сейчас
- [ ] модель передаёт `reading.member` и выбранную гонку
- [ ] тесты: v2 без пула, v2 при `poolReady = false`, v2 другой гонки, v1 в пуле / не в пуле
- [ ] run tests - must pass before task 5

### Task 5: Ключ гонки — API и Keychain

**Files:**
- Modify: `kolco24/Net/ApiClient.swift`
- Create: `kolco24/Net/Dto/MemberKey.swift`
- Create: `kolco24/Core/Stores/MemberKeyStore.swift`
- Create: `kolco24/Keychain/MemberKeyStoreKeychain.swift`
- Modify: `kolco24/App/AppEnvironment.swift`
- Create: `kolco24Tests/Net/MemberKeyDtoTests.swift`
- Create: `kolco24Tests/Core/MemberKeyStoreTests.swift`

- [ ] `ApiClient.fetchMemberKey(raceId:)` — `GET /app/race/<id>/member_key/` с bearer админа, **всегда облачный клиент**
- [ ] разбор ответа: `race_id` совпадает с запрошенным, `key` — 64 hex; иначе ошибка
- [ ] `MemberKeyStore` (протокол + Keychain-адаптер по образцу `AdminTokenStore`): `read(raceId)`, `write(raceId, key)`,
      `clearAll()`; `clearAll()` при выходе из облачной админ-сессии (`AdminSessionHolder`)
- [ ] тесты: разбор DTO, чужой `race_id`/плохой hex/длина → ошибка, store на фейковом бэкенде, ключи гонок не смешиваются
- [ ] run tests - must pass before task 6

### Task 6: Очередь привязок и GRDB-миграция `v5`

**Files:**
- Modify: `kolco24/Data/AppDatabase.swift`
- Create: `kolco24/Data/Records/PendingMemberBind+GRDB.swift`
- Create: `kolco24/Data/Stores/PendingMemberBindStore.swift`
- Create: `kolco24/Data/Repositories/MemberBindUploadRepository.swift`
- Modify: `kolco24/Net/ApiClient.swift`
- Modify: `kolco24/Net/Dto/MemberTagBind.swift`
- Modify: `kolco24/App/AppEnvironment.swift`
- Modify: `kolco24/App/AppModel.swift`
- Create: `kolco24Tests/Data/PendingMemberBindStoreTests.swift`
- Create: `kolco24Tests/Data/Repositories/MemberBindUploadRepositoryTests.swift`
- Modify: `kolco24Tests/Data/AppDatabaseSchemaTests.swift`

- [ ] миграция `v5`: таблица `pending_member_binds(raceId, nfcUid, number, codeHex, error, createdAt)`, PK `(raceId, nfcUid)`
- [ ] `bindMemberTag(raceId:nfcUid:number:code:)` — тело с `code`
- [ ] `MemberBindUploadRepository` (`actor`, `inFlight`): отправка по `adminRoute(raceId:)`, исходы — по таблице из
      Technical Details; `dismiss(raceId:nfcUid:)`; вызов там же, где загрузка judge scans в `AppModel`
- [ ] тесты: схема `v5`, повторная запись заменяет строку и сбрасывает ошибку, `200`/`201` удаляют, `400`/`409` ставят
      ошибку, `401`/`429`/`5xx`/сеть оставляют строку и прерывают проход, `dismiss`
- [ ] run tests - must pass before task 7

### Task 7: Судейская логика и модель выдачи без сети

**Files:**
- Modify: `kolco24/Core/Admin/MemberProvisioningLogic.swift`
- Modify: `kolco24/App/MemberProvisioningModel.swift`
- Modify: `kolco24Tests/Core/MemberProvisioningLogicTests.swift`
- Modify: `kolco24Tests/App/MemberProvisioningModelTests.swift`

- [ ] убрать сетевое состояние bind и переход «номер по `404`»; `needsNumber(uid, prefill)`
- [ ] состояния `alreadyWritten(uid, number)` и `forged(uid, number)` — HMAC проверяется ключом судьи; действие «Перезаписать»
- [ ] решение по тапу — по таблице из Technical Details; номер > 65535 отклоняется
- [ ] модель: при открытии `fetchMemberKey` → `MemberKeyStore`; нет ключа и fetch не удался → `needsKey`; по номеру
      `memberCode` → запись v2 и проверка чтением → строка в очереди → `uploadAllPending()` в `Task`, захватывающем репозиторий
- [ ] лента: статус очереди (`queued`/`sent`/`error`)
- [ ] тесты логики: каждая строка таблицы (включая подделку), номер > 65535, перезапись, автоинкремент, повтор после сбоя записи
- [ ] тесты модели (фейковые сканер/API/store): офлайн-выдача кладёт строку в очередь, нет ключа → `needsKey`
- [ ] run tests - must pass before task 8

### Task 8: Судейский экран выдачи

**Files:**
- Modify: `kolco24/MemberProvisioningView.swift`
- Modify: `kolco24/Localizable.xcstrings`

- [ ] экран `needsKey`: «Нужен интернет один раз, чтобы получить ключ гонки»
- [ ] «Уже записан №N» / «Подделка» + кнопка «Перезаписать»
- [ ] значки в ленте: «в очереди» / «отправлен» / «⚠ не принят сервером» с текстом ошибки и кнопкой «Убрать»
- [ ] новые строки — в `Localizable.xcstrings` (ru + en); прогнать `LocalizationTests` и `CyrillicLiteralTests`
- [ ] run tests - must pass before task 9

### Task 9: Verify acceptance criteria

- [ ] пройти Overview и Technical Details: судья выдаёт браслет офлайн, участник привязывает офлайн, станция
      старт/финиш узнаёт номер офлайн, `code` уходит в отметке
- [ ] v1-браслеты и пул работают как раньше
- [ ] grep-инварианты из CLAUDE.md (`import GRDB` только в `Data/`, `Security` только в `Keychain/`)
- [ ] полный прогон `xcodebuild test`

### Task 10: [Final] Update documentation

- [ ] `CLAUDE.md`: формат v2 и `MemberRecord` (пункт **K24 chip types**), `MemberKeyStore`, очередь привязок, миграция `v5`
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Порядок выкатки (общий для трёх репо):**
1. Сервер.
2. Выпуск с Tasks 1–4 (участник и станция читают v2).
3. Выпуск с Tasks 5–8 (судья пишет v2). Проверки минимальной версии нет: старое приложение участника увидит браслет v2
   только через пул, когда привязка дойдёт до сервера, — участников просим обновиться.

**Перед гонкой:** судьи открывают «Записать браслет», пока есть интернет (ключ из облака).

**Manual verification:**
- NTAG213 и Ultralight EV1 на iPhone: запись v2 судьёй в авиарежиме, чтение участником и станцией в авиарежиме, отметка на КП
- после включения сети: очередь ушла, на сервере `Tag` с `race`, у отметки `code_ok = True`
- браслет, записанный Android-судьёй, читается iOS-участником, и наоборот
