# Этап 11 портирования: Полировка

Детализация этапа 11 (финального) из [android-port.md](android-port.md). Этапы 0–10 выполнены: приложение функционально полное (NFC-отметки, фото, GPS-трек, dual-target upload, LAN-режим, админ-режим). Этап 11 добавляет баннер сдвига часов, празднование взятия (конфетти), аудит тёмной темы для экранов этапов 5–10, адаптивную иконку и подготовку к TestFlight.

## Overview

Четыре независимых блока полировки:

1. **Баннер сдвига часов.** `TrustedClock` уже умеет `.skewed(skewMs:)` (порог 60 с) и публикует `statusUpdates` — но стрим никто не потребляет. Появляются три поверхности (паритет с Android): глобальный баннер над вкладками (только `.skewed`), плашка в скан-оверлее (`.skewed` — красная; `.noSync` — мягкая «Время не подтверждено…», единственное место NoSync у участника) и судейский скан (`.skewed` — та же плашка; `.noSync` — заметная error-карточка: судье доверенное время критично).
2. **Празднование взятия.** По решению брейншторма — **быстрый возврат**: удержание «Готово!» 3300 мс убирается (немедленное автозакрытие), конфетти играет **на «Отметках»** после закрытия шита, а не внутри него (системная NFC-шторка всё равно перекрыла бы оверлей; участник сразу может жать «Фото» — 3-минутное окно `decidePhotoTarget` тратится меньше). Фанфара уже есть (этап 5) — не трогается.
3. **Тёмная тема.** Аудит экранов этапов 5–10 в обеих темах + точечные фиксы литеральных цветов токенами. Не редизайн.
4. **Иконка + TestFlight.** Dark/tinted-варианты иконки скриптом из существующего 1024-PNG; privacy-манифест и экспорт-комплаенс ключ; проверка Release-сборки; чек-лист ручных шагов (`docs/release.md`).

**Ключевые решения брейншторма (адаптация под платформу, не 1в1 из Kotlin):**
- **Единственный потребитель `statusUpdates` — `AppModel`.** `AsyncStream` допускает одного итератора; `AppModel.start()` запускает долгоживущий `Task` (`await trustedClock.status` для начального значения → `for await statusUpdates`) и публикует `@Observable var clockStatus`. Все поверхности читают свойство, стрим больше никто не трогает.
- **Глобальный баннер — `.safeAreaInset(edge: .top)`** на `TabView` в `ContentView` (идиоматичная замена андроидной вставки над `HorizontalPager` с ручным `consumeWindowInsets`). На `.ok`/`.noSync` — ничего (нулевая высота, как на Android). Полноэкранные каверы (`TeamPickerFlowView`/`AdminFlowView`) баннер не показывают — паритет: на Android он тоже только над вкладками.
- **`clockStatus` в шиты — параметром, не environment**: `ScanSheet` видит только `ScanModel` (конвенция этапа 5), `JudgeScanView` — только `JudgeScanModel`; параметр сохраняет это и удобен для превью. Хосты (`MarksView`, `AdminFlowView`) уже имеют `@Environment(AppModel.self)`.
- **Празднование — view-локальный `@State` в `MarksView`** (аналог андроидного plain `remember`): `ScanSheet` сигналит завершение замыканием `onCompleted` (по `closeRequested` при `didComplete`; читать `scanModel` в `onDismiss` нельзя — `.sheet(item:)` обнуляет биндинг раньше), `onDismiss` включает конфетти ~2.8 с поверх сетки, `allowsHitTesting(false)`. Никакого hand-off через `AppModel`; уход с экрана празднование честно теряет.
- **Конфетти — `TimelineView(.animation)` + `Canvas`** (подход штриховки `DarkHeroBackground`): параметры ~90 частиц генерируются один раз на запуск, каждый кадр — чистая функция от прошедшего времени. Reduce Motion (`@Environment(\.accessibilityReduceMotion)`) → конфетти не показываем, фанфара остаётся (идиоматичный iOS-штрих, на Android аналога нет).
- **1:1 из Kotlin — только `formatSkewMinutes` + его 5 тест-кейсов** (округление по модулю в `Double`); вся вёрстка и wiring — идиоматичные.
- **Иконка**: dark-вариант = прозрачный фон (системный градиент подставит iOS) + графит компаса инвертирован в светлый `E6EAF0`, красный бейдж «24» остаётся (чёрный компас на тёмном фоне исчез бы); tinted = grayscale на прозрачном. Генерация ImageMagick-скриптом в `tools/` — без дизайнера.
- **TestFlight — только подготовка проекта + чек-лист**, без автоматизации (fastlane отложен): у пользователя есть Apple Developer аккаунт, записи в App Store Connect ещё нет — ручные шаги документируются в `docs/release.md`.

## Context (from discovery)

**Уже готово и переиспользуется (не переписывать):**
- `Core/Time/TrustedClock.swift:86` — `nonisolated let statusUpdates: AsyncStream<ClockStatus>` (`.bufferingNewest(1)`, ручной дедуп) + изолированное `status`; `ClockStatus` (`noSync`/`ok`/`skewed(skewMs:)`, `SKEW_THRESHOLD_MS = 60_000`). Потребителей нет — этот этап первый.
- `App/AppModel.swift` — `start()` (Launch A), `selectedTeamStore`-observation, `toastMessage`; `AppEnvironment.trustedClock` в графе с этапа 5.
- `App/ScanModel.swift:525–560` — `beginCompletionHold()`/`handleCompletionCheck()` (FIFO-перепроверка через общий стрим, Finding-1), `defaultSuccessHoldMs = 3300`, `requestClose()`; `completed` наблюдается шитом («Готово!»-бит); фанфара `fanfareTask` (275 мс) — не трогать.
- `MarksView.swift:20,49,83–87` — `@Environment(AppModel.self)`, `.sheet(item:onDismiss:)` с `ScanSheet(model:)` и `flushUploads`-швом в `onDismiss` — точка hand-off'а празднования.
- `AdminFlowView.swift:320–327` — хост `JudgeScanView(model:)` с `@Environment(AppModel.self)` — точка проброса `clockStatus`.
- `ContentView.swift:22` — `TabView` + overlay-тост — точка `.safeAreaInset`.
- Дизайн-токены: `brandRed`/`card`/`sub`/`hairline`/`amber`, `Font.mono`, `DS.*`; `GreenCheckCircle`/`SectionHeader` в `SharedComponents.swift`.
- `Assets.xcassets/AppIcon.appiconset/` — `Contents.json` уже с тремя слотами (light/dark/tinted), все указывают на один `AppIcon-1024.png` (графитовый компас на белом + красный бейдж «24»).
- `kolco24Tests/InfoPlistTests` — прецедент ассертов «ключ доезжает до собранного plist» (этап 8, `UIBackgroundModes`).
- ImageMagick установлен (`/opt/homebrew/bin/magick`).

**Kotlin-источники** (в `/Users/alff0x1f/src/kolco24_app_v2`, пакет `app/src/main/java/ru/kolco24/kolco24/`):
- `ui/common/ClockWarningBanner.kt` — `formatSkewMinutes` (строки 31–34: `Math.round(abs(skewMs.toDouble()) / 60_000.0)` → «N мин», `abs` в `Double` — `Long.MIN_VALUE` не ловушка); глобальный `ClockWarningBanner` (только Skewed, текст «Часы телефона расходятся с сервером на N мин — проверьте дату и время»); `ScanClockBanner` (Skewed — errorContainer; NoSync — мягкая «Время не подтверждено — подключитесь к сети. Отметка всё равно будет сохранена.»).
- `MainActivity.kt:1216–1224` — единственная точка глобального баннера (над пейджером, statusBarsPadding).
- `ui/admin/JudgeScanScreen.kt:332–352, 442+` — судейский вариант: Skewed → общая плашка, NoSync → заметная error-карточка над скан-зоной.
- `ui/scan/ScanScreen.kt:107–109, 386–480` — конфетти: `CONFETTI_PIECE_COUNT = 90`, `CONFETTI_DURATION_MS = 2_800`, `ConfettiPiece` (xStart/color/sizeDp 7–14/turns 1–4/startAngle/drift ±0.2/fallFraction 0.55–0.9/delayFraction ≤ 1−fall/wobble 0.02–0.07/circle 30%), фейд последних 20% пути, прямоугольники 1:0.7 + круги; `ConfettiColors` = `E53935`, `1E88E5`, `F4B400`, `8E44AD`, `1F7A3D` (Tertiary), `C65A2E` (OrangeCta).
- **Android-тест для зеркалирования:** `ui/common/ClockWarningBannerTest.kt` — 5 кейсов: `roundsHalfUp` (150 000 → «3 мин», 149 999 → «2 мин»), `bothSignsCollapseToMagnitude` (±90 000 → «2 мин»), `justOverThresholdRoundsToOne` (±60 001 → «1 мин»), `roundsTowardNearest` (119 000 → «2 мин»), `longMinValueDoesNotTrapAndStaysPositive`. Конфетти-вёрстка на Android не тестируется (конвенция) — на iOS тоже.

**Кандидаты аудита тёмной темы (по грепу литералов):**
- `EmptyStates.swift:87` — герой-градиент захардкожен `Color(hex: "1D242D")/"2A333E"` вместо `charcoal`/`charcoalHi` → в тёмной теме не переключается на тёмный дизайн (`27313D → 171D25`). Баг, чинится токенами.
- `CheckChipView.swift:240–245` — литеральные цвета категорий КП (red/blue/yellow/purple). Вероятно осознанно (семантика цвета КП едина в обеих темах, прецедент `amber`) — проверить контраст на тёмном фоне, при необходимости завести адаптивные пары.
- **Не трогать** (документированные fixed-dark): `PhotoCaptureView`/`PhotoLightboxView` (чёрные по дизайну), `NFCTileView`, `DarkHeroBackground`, белый `CPBadge`.

## Development Approach

- **testing approach**: порт-конвенция этапов 2–10 — Kotlin-тесты переносятся вместе с модулем в той же задаче (имена кейсов 1:1, header «Зеркало …»); для `AppModel.clockStatus` и `ScanModel.didComplete` зеркала нет — тесты свежие (regular: код → тесты в той же задаче). Вёрстка (баннеры, конфетти, иконка) unit-тестов не имеет — ворота: сборка + глаза (конвенция всех этапов);
- complete each task fully before moving to the next;
- make small, focused changes (коммит на задачу);
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task (кроме чисто визуальных — там explicit «no tests» с проверкой сборкой);
- **CRITICAL: all tests must pass before starting next task**;
- **CRITICAL: update this plan file when scope changes during implementation**.

## Testing Strategy

- **unit tests**: Swift Testing. Новое: `kolco24Tests/Core/SkewFormatTests` (зеркало `ClockWarningBannerTest.kt`, 5 кейсов). Дополнения: `AppModelTests` (republish `clockStatus` из `TrustedClock` через `AppEnvironment.inMemory`), `ScanModelTests` (`didComplete` на ребре завершения; не выставлен при истечении окна; немедленный `closeRequested` при `successHoldMs = 0`), `InfoPlistTests` (`ITSAppUsesNonExemptEncryption` и `PrivacyInfo.xcprivacy` доезжают до собранного бандла).
- **e2e**: автоматизированных нет. Баннер по живому сдвигу часов, конфетти, иконка в 3 режимах, TestFlight — руками (Post-Completion).
- Прогон: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'` (нужен `Config/Secrets.xcconfig`; при флаки-имени — `id=<UDID>` из `xcrun simctl list devices available`).

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix
- update plan if implementation deviates from original scope

## Implementation Steps

### Task 1: Core `formatSkewMinutes` + зеркальные тесты

**Files:**
- Create: `kolco24/Core/Time/SkewFormat.swift`
- Create: `kolco24Tests/Core/SkewFormatTests.swift`

- [x] `formatSkewMinutes(_ skewMs: Int64) -> String` — порт 1:1 (`ClockWarningBanner.kt:31–34`): округление по модулю `(abs(Double(skewMs)) / 60_000).rounded()` → «N мин», без направления; `abs` в `Double` (не `Int64` — `Int64.min` не ловушка). Foundation-only (греп-инвариант `Core/`)
- [x] зеркало 5 кейсов `ClockWarningBannerTest.kt` (имена 1:1: `roundsHalfUp`, `bothSignsCollapseToMagnitude`, `justOverThresholdRoundsToOne`, `roundsTowardNearest`, `longMinValueDoesNotTrapAndStaysPositive`), header «Зеркало ClockWarningBannerTest.kt»
- [x] проверить полу-к-верху семантику: Kotlin `Math.round(2.5) = 3` ↔ Swift `.rounded(.toNearestOrAwayFromZero)` на положительном `abs` эквивалентен — кейс `roundsHalfUp` это фиксирует
- [x] run tests — must pass before task 2

### Task 2: `AppModel.clockStatus` — единственный потребитель `statusUpdates`

**Files:**
- Modify: `kolco24/App/AppModel.swift`
- Modify: `kolco24Tests/App/AppModelTests.swift`

- [x] `var clockStatus: ClockStatus = .noSync` (@Observable, публичное чтение); в `start()` — долгоживущий `Task`: `clockStatus = await trustedClock.status`, затем `for await s in trustedClock.statusUpdates { clockStatus = s }` (идиома существующих подписок; отмена вместе с моделью)
- [x] **guard от повторного входа** (finding plan-review): `statusUpdates` — одно-итераторный `AsyncStream`, второй `for await` = runtime fault; подписку хранить в `clockStatusTask` и гардить `guard clockStatusTask == nil` (идиома `startSelectionObservationIfNeeded`) — корневой `.task` в `kolco24App` теоретически может перезапуститься
- [x] fresh-тест в `AppModelTests`: `AppEnvironment.inMemory` → `start()` → толкнуть `trustedClock` в skew (через `onServerTime`-якорь + подмену `wallProvider`, как в `TrustedClockTests`) → дождаться `clockStatus == .skewed` (идиома поллинга существующих async-тестов)
- [x] run tests — must pass before task 3

### Task 3: Три поверхности баннера (вёрстка + проброс)

**Files:**
- Create: `kolco24/ClockBanners.swift`
- Modify: `kolco24/ContentView.swift`
- Modify: `kolco24/MarksView.swift`
- Modify: `kolco24/ScanSheet.swift`
- Modify: `kolco24/AdminFlowView.swift`
- Modify: `kolco24/JudgeScanView.swift`

- [ ] `ClockBanners.swift`: переиспользуемый ряд (иконка + текст, токены) в двух стилях — «skewed» (`brandRed`-контейнер, белый текст, иконка `clock.badge.exclamationmark`) и «мягкий noSync» (`card`-фон, `sub`-текст, иконка `icloud.slash`); + заметная судейская NoSync-карточка (аналог `JudgeScanScreen.kt:442+`). Тексты байт-в-байт с Android: «Часы телефона расходятся с сервером на {formatSkewMinutes} — проверьте дату и время», «Время не подтверждено — подключитесь к сети. Отметка всё равно будет сохранена.»
- [ ] `ContentView`: `.safeAreaInset(edge: .top)` на `TabView` — глобальный баннер только при `.skewed`, иначе `EmptyView` (нулевая высота); анимация появления как у тоста
- [ ] `ScanSheet` получает `clockStatus: ClockStatus` параметром (от `MarksView` через `appModel.clockStatus`); плашка над CP-карточкой: `.skewed` → красная, `.noSync` → мягкая, `.ok` → ничего; превью обновить (все три состояния)
- [ ] `JudgeScanView` получает `clockStatus: ClockStatus` параметром; **два call-site'а** (finding plan-review): хост в `AdminFlowView.swift:~327` и превью-хост в `JudgeScanView.swift:225` (+ `#Preview`-блоки 266/270); `.skewed` → общая плашка, `.noSync` → судейская error-карточка над скан-зоной, `.ok` → ничего
- [ ] no new unit tests (вёрстка); ворота — сборка + существующие тесты зелёные; run tests — must pass before task 4

### Task 4: Быстрое автозакрытие + `didComplete` в `ScanModel`

**Files:**
- Modify: `kolco24/App/ScanModel.swift`
- Modify: `kolco24Tests/App/ScanModelTests.swift`

- [ ] `defaultSuccessHoldMs` 3300 → 0: механизм холда (FIFO-перепроверка `completionCheck`, Finding-1) **не трогается** — просто нулевая задержка; «Готово!»-бит остаётся видимым на время анимации закрытия шита
- [ ] `private(set) var didComplete = false` — выставляется в `handleCompletionCheck()` перед `finalizeSession()` (только успешное завершение; истечение окна его НЕ выставляет); `@ObservationIgnored` не нужен — флаг читается после dismiss
- [ ] фанфару (`fanfareTask`, 275 мс) не трогать — играет независимо от закрытия
- [ ] обновить/добавить кейсы `ScanModelTests`: с `successHoldMs = 0` завершение → `closeRequested` без задержки + `didComplete == true`; истечение окна → `closeRequested`, `didComplete == false`; существующие кейсы с инжектированным холдом остаются валидны
- [ ] run tests — must pass before task 5

### Task 5: `ConfettiOverlay` + празднование на «Отметках»

**Files:**
- Create: `kolco24/ConfettiOverlay.swift`
- Modify: `kolco24/MarksView.swift`
- Modify: `kolco24/ScanSheet.swift`

- [ ] `ConfettiOverlay(running: Bool)`: `TimelineView(.animation)` + `Canvas`; 90 частиц по спецификации `ScanScreen.kt:401–480` (поля `ConfettiPiece`, стагер `delay + fall ≤ 1`, фейд последних 20%, прямоугольники 1:0.7 + 30% кругов, sway-синусоида); длительность 2.8 с; палитра `E53935`/`1E88E5`/`F4B400`/`8E44AD`/`1F7A3D`/`C65A2E` через `Color(hex:)`; частицы генерируются один раз на запуск (`@State`, пересоздание по `running`-ребру)
- [ ] **hand-off НЕ через чтение `scanModel` в `onDismiss`** (critical finding plan-review): у `.sheet(item: $scanModel)` биндинг обнуляется **до** `onDismiss`, `scanModel?.didComplete` там всегда `nil` (существующий `flushAfterScan` работает лишь потому, что читает только `appModel`). Вместо этого: `ScanSheet` получает замыкание `onCompleted: () -> Void`; в его существующем `.onChange(of: model.closeRequested)` при `model.didComplete` — вызвать `onCompleted()` перед `dismiss()`
- [ ] `MarksView`: `@State pendingCelebration = false` (выставляет `onCompleted`) + `@State celebrating = false`; в `onDismiss` (рядом с `flushAfterScan`) — `if pendingCelebration { pendingCelebration = false; celebrating = true }` (конфетти стартует, когда шит уже ушёл); `ConfettiOverlay` поверх контента, `allowsHitTesting(false)` (FAB «Фото» кликабелен сразу); автосброс `celebrating` по `.task` через ~2.8 с
- [ ] Reduce Motion: `@Environment(\.accessibilityReduceMotion)` → при `true` конфетти не запускается (фанфара уже отыграла из `ScanModel`)
- [ ] no unit tests (визуальный код, конвенция Android — конфетти там тоже не тестируется); проверка глазами: превью + симулятор с `FakeChipScanner`-флоу
- [ ] run tests — must pass before task 6

### Task 6: Аудит тёмной темы (экраны этапов 5–10)

**Files:**
- Modify: `kolco24/EmptyStates.swift`
- Modify: `kolco24/CheckChipView.swift` (по результату аудита)
- Modify: прочие вьюхи по найденному (точечно)

- [ ] `EmptyStates.swift:87`: литеральный градиент → токены `charcoal`/`charcoalHi` (получает тёмный дизайн `27313D → 171D25` автоматически)
- [ ] прогон в симуляторе в обеих темах (переключатель «Внешний вид» этапа 9): `ScanSheet`, `BindChipSheet`, `UploadView`, `SettingsView`, `PhotoNumberPickerView`, `AdminFlowView` + логин + 4 подэкрана (судейский, 2 проверки чипа, провижининг), тост/баннеры этого этапа
- [ ] `CheckChipView.swift:240–245`: проверить контраст цветов КП на тёмном фоне; если читается — оставить литералами с комментарием (прецедент `amber`), нет — адаптивные пары `Color(light:dark:)`
- [ ] найденные проблемы чинить **только токенами** (без новых литералов, кроме документированных fixed-dark); список фиксов зафиксировать в этом файле (➕)
- [ ] no unit tests (визуальная работа); сборка зелёная; run tests — must pass before task 7

### Task 7: Иконка — dark/tinted-варианты

**Files:**
- Create: `tools/appicon-variants.sh`
- Create: `kolco24/Assets.xcassets/AppIcon.appiconset/AppIcon-1024-dark.png`
- Create: `kolco24/Assets.xcassets/AppIcon.appiconset/AppIcon-1024-tinted.png`
- Modify: `kolco24/Assets.xcassets/AppIcon.appiconset/Contents.json`

- [ ] скрипт на ImageMagick (`magick` есть в brew): **dark** — белый фон → прозрачный, графит компаса (`~#26262E`) → светлый `E6EAF0`, красный бейдж «24» без изменений; **tinted** — grayscale на прозрачном фоне (систему iOS 18 красит сама)
- [ ] `Contents.json`: dark/tinted-слоты → новые filenames (слоты уже существуют)
- [ ] проверка глазами: домашний экран симулятора в режимах Light / Dark / Tinted
- [ ] no unit tests; сборка зелёная (asset-каталог валиден); run tests — must pass before task 8

### Task 8: TestFlight-подготовка проекта

**Files:**
- Modify: `kolco24/Info.plist`
- Create: `kolco24/PrivacyInfo.xcprivacy`
- Modify: `kolco24Tests/InfoPlistTests.swift`
- Create: `docs/release.md`

- [ ] `Info.plist`: `ITSAppUsesNonExemptEncryption = false` (только HTTPS — экземпт; убирает вопрос экспорт-комплаенса на каждой загрузке)
- [ ] `PrivacyInfo.xcprivacy` (`NSPrivacyAccessedAPITypes`): `NSPrivacyAccessedAPICategoryUserDefaults` → `CA92.1` (свои `InstallId`/`ClockAnchorStore`/`ThemePreference`/`RaceLeaseStore`); `NSPrivacyAccessedAPICategorySystemBootTime` → `35F9.1` (`mach_continuous_time` в `SystemClockProviders`, `CoreLocationProvider`, `CLLocationMapping`, `CoreLocationTrackEngine`, `ApiClient` — везде измерение прошедшего времени; одна запись покрывает все). GRDB свой манифест везёт. Файл должен попасть в бандл как ресурс — synchronized group это делает сам (в отличие от `Info.plist` исключение НЕ нужно)
- [ ] `InfoPlistTests`: ассерты в стиле `backgroundLocationModeIsDeclared` — `ITSAppUsesNonExemptEncryption == false` в собранном plist; `PrivacyInfo.xcprivacy` присутствует в бандле
- [ ] Release-сборка проходит: `xcodebuild -project kolco24.xcodeproj -scheme kolco24 -configuration Release -destination 'platform=iOS Simulator,name=iPhone 16' build` (`Secrets.xcconfig` — база обеих конфигураций через `App.xcconfig`; `MARKETING_VERSION = 1.0` / `CURRENT_PROJECT_VERSION = 1` — ок для первой загрузки)
- [ ] `docs/release.md` — чек-лист ручных шагов (см. Post-Completion): App ID + NFC Tag Reading capability, запись в App Store Connect, signing team в Xcode, Organizer → Archive → Upload, Internal Testing группа, инкремент build-номера на повторных загрузках
- [ ] run tests — must pass before task 9

### Task 9: Verify acceptance criteria

- [ ] баннер: глобальный только на `.skewed`; NoSync виден только в скан-оверлее (мягко) и судейском скане (карточка); тексты байт-в-байт с Android
- [ ] празднование: завершение взятия → шит закрывается немедленно, конфетти на «Отметках», FAB «Фото» кликабелен; истечение окна → без празднования; Reduce Motion → без конфетти
- [ ] тёмная тема: все экраны этапов 5–10 корректны в обеих темах; fixed-dark поверхности не тронуты
- [ ] иконка: три режима на домашнем экране; Release-сборка зелёная
- [ ] полный сьют: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'`
- [ ] греп-инварианты: `Core/Time/SkewFormat` — Foundation-only; `AppModel`/`ScanModel` — только `Observation`/`Foundation`; новые вьюхи — в корне `kolco24/`; `import GRDB` не расползся

### Task 10: [Final] Документация

- [ ] `CLAUDE.md`: секция этапа 11 (баннер часов + единственный потребитель `statusUpdates`, быстрое закрытие + `didComplete` + конфетти, фиксы тёмной темы, иконка, privacy-манифест, `docs/release.md`)
- [ ] `docs/plans/android-port.md`: этап 11 → «✅ выполнен — см. [детальный план](completed/20260712-android-port-stage11.md)» с кратким резюме решений
- [ ] переместить этот план в `docs/plans/completed/`

## Post-Completion

*Ручные шаги — вне кода, по чек-листу `docs/release.md`:*

**Developer Portal / App Store Connect (у пользователя есть аккаунт, записи приложения нет):**
- зарегистрировать App ID `kolco24.ru.kolco24` с capability **NFC Tag Reading** (это entitlement на App ID, не только plist-ключ);
- создать запись приложения в App Store Connect (имя, primary language ru, bundle id, SKU);
- в Xcode: signing team на таргете, Automatic signing; Archive (Any iOS Device) → Organizer → Distribute → App Store Connect → Upload;
- в ASC: дождаться обработки билда, заполнить App Privacy (сбор геолокации — трек/анти-фрод; связана с пользователем через команду), создать Internal Testing группу, добавить тестеров.

**Живая верификация на устройстве:**
- баннер сдвига: перевести часы телефона на >2 мин при выключенной автоустановке → после любого запроса к серверу баннер появляется, «N мин» совпадает; вернуть часы → пропадает после следующего якоря;
- NoSync-плашка: свежая установка без сети → открыть скан-оверлей;
- конфетти + фанфара: полное взятие на реальных чипах;
- иконка на реальном устройстве в трёх режимах;
- TestFlight: установка через приглашение, smoke-тест основных флоу.
