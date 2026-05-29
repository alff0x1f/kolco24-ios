# Plan: тёмная тема (dark mode)

**Дата:** 2026-05-29
**Ветка:** `feature/dark-theme`
**Источник дизайна:** `tmp/design.html` (light) и `tmp/design_dark.html` (dark) — отличаются только таблицей цветовых токенов.

## Overview

Приложение сейчас реализует только светлую тему: цвета жёстко зашиты в `DesignTokens.swift`
(`Color(hex:)`) и в виде литералов (`Color.white`, `Color.black.opacity(...)`) по вью.
Нужно добавить тёмную тему, **следуя системной** настройке iOS — без экрана настроек и без
хранения выбора. Выбранный подход — **динамические цвета в Swift** через
`UIColor(dynamicProvider:)`: вся палитра остаётся в одном файле и построчно зеркалит таблицу
токенов из `design_dark.html`, а система сама переключает тему по trait'у.

**Проблема, которую решаем:** в тёмной системной теме приложение выглядит сломанным (белые
карточки, чёрные тени на чёрном). **Выгода:** единый источник правды для палитры, авто-переключение
без UI, минимум точечных правок визуала.

**Интеграция:** существующие имена токенов (`Color.ink`, `Color.card` и т.д.) сохраняются — вью
продолжают ссылаться на них как раньше, меняется только их определение на адаптивное.

## Принципы / границы

- Перекраска через токены + одно точечное изменение визуала (NFC-плитка, см. Task 3).
  Никаких новых экранов, переключателей, persistence.
- Контент, одинаковый в обеих темах, **не трогаем:** градиенты-превью фото КП, белый
  светоотражающий `CPBadge`/`MiniCPBadge`, белый текст и штриховка на тёмном «герое».
- **Вне объёма:** синхронизация html-макетов в `tmp/` — они только референс, меняем лишь Swift-код.

## Context (from discovery)

- **Файлы/компоненты:** `DesignTokens.swift` (палитра + `Color(hex:)` + `enum DS`),
  `SharedComponents.swift`, `MarksView.swift`, `ScanSheet.swift`, `TeamView.swift`,
  `LegendView.swift`.
- **Найденные паттерны:**
  - токены живут в `extension Color` как `static let … = Color(hex: "…")` (9 токенов);
  - поверхности/линии/тени по вью заданы литералами (`Color.white`, `Color.black.opacity(...)`);
  - повторяющийся визуальный мотив — диагональная штриховка через `Canvas`
    (`NFCTileView`, `PhotoTileView`, `DarkHeroBackground`);
  - тёмный «герой» (`DarkHeroBackground`, `TimerHeroView`, `TeamHeroView`) уже использует
    фиксированный белый контент — он корректен в обеих темах.
- **Зависимости:** только SwiftUI/UIKit (`UIColor(dynamicProvider:)`); сетей/persistence нет.
- **Проверено:** ссылки на строки в `MarksView.swift` и определения токенов в
  `DesignTokens.swift` совпадают с текущим кодом (поле `isRecent` — `MarksView.swift:10`,
  мок — `:22`, overlay-кольцо — `:114–116` и `:155–157`).

## Development Approach

- **Testing approach (выбор пользователя): без авто-тестов.** Юнит-тестами реально покрывалась
  бы только логика разрешения адаптивного цвета, но пользователь явно выбрал не добавлять их.
  Гейт каждой задачи — **успешная сборка** (`xcodebuild … build`), для задач с заменой литералов
  дополнительно **grep-аудит** оставшихся «поверхностных» литералов. Визуальная сверка — вручную
  (см. Post-Completion).
- complete each task fully before moving to the next.
- small, focused changes; сборка зелёная перед переходом к следующей задаче — без исключений.
- **CRITICAL: update this plan file when scope changes during implementation.**
- maintain backward compatibility — имена токенов и публичные сигнатуры вью не меняем.

## Testing Strategy

Это чисто визуальная перекраска SwiftUI; автоматических unit/e2e-тестов в проекте по этой задаче
не заводим (явный выбор пользователя). Вместо них — три гейта:

- **Сборка:** `xcodebuild -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16' build`
  должна проходить после каждой задачи.
- **grep-аудит литералов** (после задач с заменой и в финальной проверке):
  `grep -rnE "\.white|Color\.black|\.black\.opacity" kolco24/*.swift` — в выдаче допустимы
  только герой/контент/фиксированный визуал чип-карты, «поверхностных» литералов быть не должно.
- **Визуальная сверка** (вручную, Post-Completion): Xcode previews `.dark` + Environment Overrides →
  Appearance на 4 экранах против `tmp/design_dark.html`.

> Примечание: существующие `kolco24Tests`/`kolco24UITests` (плейсхолдеры) не трогаем и не ломаем —
> они должны продолжать собираться.

## Progress Tracking

- mark completed items with `[x]` immediately when done.
- add newly discovered tasks with ➕ prefix.
- document issues/blockers with ⚠️ prefix.
- update plan if implementation deviates from original scope.

## Solution Overview

Один адаптивный инициализатор `Color(light:dark:)` поверх `UIColor(dynamicProvider:)` делает
все токены реагирующими на `userInterfaceStyle`. Палитра остаётся единственным источником правды;
вью переводятся с литералов на новые токены поверхностей/линий/теней. Два элемента остаются
фиксированно-тёмными в обеих темах (тёмный «герой» — уже такой; NFC-плитка — становится такой,
переписанная в «чип-карту»). Мёртвая фича `isRecent` удаляется заодно. Выбор темы целиком отдаётся
системе — никакого UI, состояния и хранения.

**Ключевые решения:**
- `UIColor(dynamicProvider:)` вместо asset-каталога — вся палитра в одном Swift-файле, рядом с
  таблицей токенов, легко ревьюить против html.
- Прозрачные токены (`hairline`, `cardShadow`) несут alpha внутри себя — выбрать на этапе
  реализации форму хелпера (`Color(light:dark:)` с заданной alpha либо расширение
  `init(lightUI:darkUI:)` поверх `UIColor`).
- NFC-плитка — фиксированный тёмный визуал (как `DarkHeroBackground`), не адаптивные токены.

## Technical Details

### Адаптивный инициализатор (Task 1)

```swift
extension Color {
    init(light: String, dark: String) {
        self.init(uiColor: UIColor { trait in
            UIColor(Color(hex: trait.userInterfaceStyle == .dark ? dark : light))
        })
    }
}
```

### 9 существующих токенов → адаптивные (значения dark — из `design_dark.html`)

| токен          | light  | dark   |
|----------------|--------|--------|
| `ink`          | 161A1F | F2F4F7 |
| `sub`          | 56606A | 98A2AD |
| `paper`        | EEF0F3 | 0C0F14 |
| `brandRed`     | C3011C | FF4759 |
| `kolcoOrange`  | C65A2E | F0763C |
| `good`         | 1F7A3D | 34C759 |
| `charcoal`     | 1D242D | 27313D |
| `charcoalHi`   | 2A323C | 171D25 |
| `amber`        | F2B36B | F2B36B (без изменений — оставить `Color(hex:)`) |

### 3 новых токена (сейчас живут как литералы)

| токен        | light                | dark                 | заменяет                                  |
|--------------|----------------------|----------------------|-------------------------------------------|
| `card`       | FFFFFF               | 181D24               | `Color.white` как фон карточек            |
| `hairline`   | black α0.08–0.13     | white α0.08–0.12     | разделители/обводки `Color.black.opacity(...)` |
| `cardShadow` | black α≈0.05         | black α≈0.45         | `.shadow(color: .black.opacity(...))`     |

Альфа из html: light HAIR `rgba(60,60,67,0.13)` / dark HAIR `rgba(255,255,255,0.08)`;
dark карточная тень `rgba(0,0,0,0.45)`. Т.к. `hairline`/`cardShadow` несут прозрачность —
реализовать через `Color(light:dark:)` с заданной alpha (или расширить хелпер до
`init(lightUI:darkUI:)`, принимающего `UIColor`); выбрать в момент реализации.

### NFC-плитка → тёмная «чип-карта» (Task 3)

`NFCTileView` (`MarksView.swift:87–119`) перестаёт быть белой плиткой и становится
**самостоятельно-тёмным элементом, одинаковым в обеих темах** (как `DarkHeroBackground`),
по образцу NFC-плитки из `design_dark.html`. Использует фиксированные `Color(hex:)`, **не**
адаптивные токены:
- фон: линейный градиент `#171D25 → #232A33` (≈155°);
- inset-тени для «утопленности» + субтильная диагональная штриховка (white α≈0.025);
- глиф бесконтактной оплаты — три дуги цветом `#E6EAF0` (вместо текущего белого фона);
- номер: белый mono (28, bold) с лёгкой тенью;
- **красные полоски убрать** (атрибут светлой отражающей плитки; в чип-карте их нет).

`PhotoTileView` и её `MiniCPBadge` (белый с красной полоской) — без изменений.

## What Goes Where

- **Implementation Steps** (`[ ]`): правки Swift-кода + сборка + grep-аудит — всё, что делается в репозитории.
- **Post-Completion** (без чекбоксов): ручная визуальная сверка в симуляторе/Xcode и сравнение с
  `design_dark.html` — требует глаз и интерактивного запуска.

## Implementation Steps

### Task 1: Адаптивный хелпер цвета + адаптивные/новые токены

**Files:**
- Modify: `kolco24/DesignTokens.swift`

- [x] добавить `init(light:dark:)` в `extension Color` поверх `UIColor(dynamicProvider:)`
- [x] (при необходимости) добавить вариант хелпера для прозрачных токенов (`init(lightUI:darkUI:)` на `UIColor`)
- [x] перевести 9 токенов на `Color(light:dark:)` по таблице (`amber` оставить `Color(hex:)`)
- [x] добавить токены `card`, `hairline`, `cardShadow` с alpha из html
- [x] собрать проект — сборка должна проходить перед Task 2

### Task 2: Замена литералов поверхностей/линий/теней во вью

**Files:**
- Modify: `kolco24/SharedComponents.swift`
- Modify: `kolco24/ScanSheet.swift`
- Modify: `kolco24/TeamView.swift`
- Modify: `kolco24/LegendView.swift`
- Modify: `kolco24/MarksView.swift` (только поверхности/линии/тени; чип-карта и `isRecent` — Task 3/4)

**Поверхности → `Color.card`:**
- [x] `MarksView.swift:49` (метрики), `:228` (кнопка «Фото» → `Color.card.opacity(0.92)` — сохранена полупрозрачность над `.ultraThinMaterial`)
- [x] `ScanSheet.swift:107`, `:160`
- [x] `TeamView.swift:54`, `:80`, `:234`
- [x] `LegendView.swift:77` (`listRowBackground`), `:134`, `:200` (активный сегмент)

**Линии/обводки → `Color.hairline`:**
- [x] `SharedComponents.swift:25`, `:65`
- [x] `MarksView.swift:117`, `:158`, `:232` (canvas-штрих `:101` α0.018 — **оставлено как есть**)
- [x] `ScanSheet.swift:94`, `:101`, `:126`
- [x] `TeamView.swift:48`, `:73`, `:238`
- [x] `LegendView.swift:121`, `:203`

**Тени → `Color.cardShadow`:**
- [x] `MarksView.swift:51`, `:234`
- [x] `ScanSheet.swift:109`, `:162`
- [x] `TeamView.swift:240`, `:262`
- [x] `LegendView.swift:136`

**Сегментед-контрол (`LegendView`):**
- [x] трек переведён на `Color.sub.opacity(0.2)`, активный сегмент — на `Color.card` (читаемость в dark; финальная сверка — Post-Completion)

➕ **Дополнительно найдено и исправлено (литералы вне исходного списка, ломались в dark):**
- `ScanSheet.swift:34` — ручка sheet `Color.black.opacity(0.2)` → `Color.sub.opacity(0.35)` (на тёмном `paper` чёрная ручка была невидима).
- `LegendView.swift:196` — счётчик неактивного сегмента `Color(hex: "3C3C43").opacity(0.5)` → `Color.sub.opacity(0.5)` (тёмно-серый на тёмном фоне был нечитаем).

**Не трогать (`.white` — корректно в обеих темах):** `ScanSheet.swift:180,231,240,243,257,263,267`
(таймер-герой); `TeamView.swift:105,113,116,122,133,138,139,145` (TeamHero) + `:265` (белый глиф иконки на цветном фоне MiscRow);
`SharedComponents.swift:13` (`CPBadge`), `:97` (галочка), `:124` (штриховка героя);
`MarksView.swift:209` (текст на оранжевой CTA), фото-градиенты `:144,148`;
`MarksView.swift:94,101` (заливка/штриховка NFC-плитки — переписываются в Task 3).

- [x] собрать проект — сборка проходит (`** BUILD SUCCEEDED **`)
- [x] grep-аудит: `grep -rnE "\.white|Color\.black|\.black\.opacity" kolco24/*.swift` — остались только герой/контент/фиксированный визуал + NFC-плитка (Task 3); перейти к Task 3

### Task 3: Переписать `NFCTileView` в тёмную «чип-карту»

**Files:**
- Modify: `kolco24/MarksView.swift` (`NFCTileView`, ~`:87–119`)

- [ ] фон: линейный градиент `#171D25 → #232A33` (≈155°), фиксированные `Color(hex:)`
- [ ] inset-тени «утопленности» + диагональная штриховка white α≈0.025 (мотив `Canvas`)
- [ ] глиф бесконтактной оплаты — три дуги цветом `#E6EAF0`
- [ ] номер — белый mono (28, bold) с лёгкой тенью
- [ ] убрать красные полоски (атрибут светлой плитки)
- [ ] убедиться, что `PhotoTileView`/`MiniCPBadge` не затронуты
- [ ] собрать проект — сборка должна проходить перед Task 4

### Task 4: Удалить `isRecent`-кольцо и мёртвое поле

**Files:**
- Modify: `kolco24/MarksView.swift`

- [ ] удалить `.overlay { if tile.isRecent { … strokeBorder(Color.good …) } }` в `NFCTileView` (`:114–116`) и `PhotoTileView` (`:155–157`)
- [ ] удалить поле `CheckpointTile.isRecent` (`:10`)
- [ ] вычистить `isRecent: true` из мока `mockTiles` (`:22`)
- [ ] собрать проект — сборка должна проходить; `grep -rn "isRecent" kolco24/` пустой

### Task 5: Dark-превью на всех экранах

**Files:**
- Modify: `kolco24/MarksView.swift`, `kolco24/LegendView.swift`, `kolco24/ScanSheet.swift`, `kolco24/TeamView.swift` (блоки `#Preview`)

- [ ] в каждый `#Preview` добавить вариант `.preferredColorScheme(.dark)` (или второй preview), чтобы видеть обе темы рядом
- [ ] собрать проект — сборка должна проходить; previews рендерятся в обеих темах

### Task 6: Verify acceptance criteria

- [ ] выполнены все требования Overview: 9 токенов адаптивны, 3 новых добавлены, литералы заменены, NFC-плитка = чип-карта, `isRecent` удалён, dark-превью есть
- [ ] финальная сборка: `xcodebuild -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16' build`
- [ ] финальный grep-аудит: `grep -rnE "\.white|Color\.black|\.black\.opacity" kolco24/*.swift` — только герой/контент/чип-карта
- [ ] `grep -rn "isRecent" kolco24/` — пусто

### Task 7: [Final] Обновить документацию

**Files:**
- Modify: `CLAUDE.md`

- [ ] обновить раздел «Design system» в `CLAUDE.md`: палитра теперь адаптивная (`Color(light:dark:)`), новые токены `card`/`hairline`/`cardShadow`
- [ ] зафиксировать мотив: NFC-плитка — фиксированно-тёмная чип-карта; `isRecent` удалён
- [ ] переместить план в `docs/plans/completed/` (создать каталог при необходимости)

## Post-Completion
*Items requiring manual intervention — no checkboxes, informational only*

**Manual verification:**
- запустить в симуляторе iPhone 16; в Xcode переключать Environment Overrides → Appearance
  (Light/Dark) на каждом из 4 экранов: Отметки, Легенда, Отметить КП (sheet), Команда.
- свериться визуально с `tmp/design_dark.html` по каждому экрану (поверхности, линии, тени,
  читаемость сегментед-контрола в dark, вид чип-карты).
- убедиться, что тёмный «герой» и фото-градиенты выглядят корректно в обеих темах.

**External system updates:**
- html-макеты в `tmp/` синхронизировать не нужно — они только референс (вне объёма).
