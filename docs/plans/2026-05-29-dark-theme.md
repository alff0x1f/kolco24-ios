# Plan: тёмная тема (dark mode)

**Дата:** 2026-05-29
**Ветка:** `feature/dark-theme`
**Источник дизайна:** `tmp/design.html` (light) и `tmp/design_dark.html` (dark) — отличаются только таблицей цветовых токенов.

## Цель

Приложение сейчас реализует только светлую тему: цвета жёстко зашиты в `DesignTokens.swift`
(`Color(hex:)`) и в виде литералов (`Color.white`, `Color.black.opacity(...)`) по вью.
Нужно добавить тёмную тему, **следуя системной** настройке iOS (без экрана настроек и без хранения
выбора). Выбранный подход — **динамические цвета в Swift** через `UIColor(dynamicProvider:)`:
вся палитра остаётся в одном файле и построчно зеркалит таблицу токенов из `design_dark.html`,
а система сама переключает тему по trait'у.

## Принципы / границы

- Перекраска через токены + одно точечное изменение визуала (NFC-плитка, см. Шаг 2).
  Никаких новых экранов, переключателей, persistence.
- Контент, одинаковый в обеих темах, **не трогаем:** градиенты-превью фото КП, белый
  светоотражающий `CPBadge`/`MiniCPBadge`, белый текст и штриховка на тёмном «герое».
- **Вне объёма:** синхронизация html-макетов в `tmp/` — они только референс, меняем
  лишь Swift-код.

---

## Шаг 1 — слой токенов (`DesignTokens.swift`)

Добавить инициализатор адаптивного цвета:

```swift
extension Color {
    init(light: String, dark: String) {
        self.init(uiColor: UIColor { trait in
            UIColor(Color(hex: trait.userInterfaceStyle == .dark ? dark : light))
        })
    }
}
```

Сделать 9 существующих токенов адаптивными (значения dark — из `design_dark.html`):

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

Добавить 3 новых токена (сейчас живут как литералы):

| токен        | light                | dark                 | заменяет                                  |
|--------------|----------------------|----------------------|-------------------------------------------|
| `card`       | FFFFFF               | 181D24               | `Color.white` как фон карточек            |
| `hairline`   | `Color(light:dark:)` поверх UIColor с alpha; light = black α0.08–0.13, dark = white α0.08–0.12 | разделители/обводки `Color.black.opacity(...)` |
| `cardShadow` | black α≈0.05         | black α≈0.45         | `.shadow(color: .black.opacity(...))`     |

Замечания по реализации:
- `hairline`/`cardShadow` несут прозрачность, поэтому через `Color(light:dark:)` с уже
  заданной alpha (можно расширить хелпер до `init(lightUI:darkUI:)` принимающего `UIColor`,
  либо хранить как функцию-провайдер). Выбрать в момент реализации, но альфа из html:
  light HAIR `rgba(60,60,67,0.13)` / dark HAIR `rgba(255,255,255,0.08)`;
  dark карточная тень `rgba(0,0,0,0.45)`.

## Шаг 2 — замена литералов во вью

Заменить по карте классификации. **Поверхности → `Color.card`:**
- `MarksView.swift:49` (метрики), `:228` (кнопка «Фото», `Color.white.opacity(0.92)`)
- `ScanSheet.swift:107`, `:160`
- `TeamView.swift:54`, `:80`, `:234`
- `LegendView.swift:77` (`listRowBackground`), `:134`, `:200` (активный сегмент)

**Линии/обводки → `Color.hairline`:**
- `SharedComponents.swift:25`, `:65`
- `MarksView.swift:117`, `:158`, `:232` (canvas-штрихи `:101` α0.018 — оставить как есть, субтильно)
- `ScanSheet.swift:94`, `:101`, `:126`
- `TeamView.swift:48`, `:73`, `:238`
- `LegendView.swift:121`, `:203`

**Тени → `Color.cardShadow`:**
- `MarksView.swift:51`, `:234`
- `ScanSheet.swift:109`, `:162`
- `TeamView.swift:240`, `:262`
- `LegendView.swift:136`

**Оставить `.white` (тёмный герой / контент — корректно в обеих темах):**
- `ScanSheet.swift:180, 231, 240, 243, 257, 263, 267` — таймер-герой
- `TeamView.swift:105, 113, 116, 122, 133, 138, 139, 145` — TeamHero
- `SharedComponents.swift:13` (`CPBadge` белый), `:97` (галочка на зелёном), `:124` (штриховка героя)
- `MarksView.swift:209` (белый текст на оранжевой CTA), фото-градиенты `:127–130, 144, 148`

**Сегментед-контрол (`LegendView`):** трек и активный сегмент — проверить читаемость в dark;
при необходимости трек = `Color.sub.opacity(0.2)`, активный = `Color.card`.

## Шаг 2б — переписать `NFCTileView` в тёмную «чип-карту»

`NFCTileView` (`MarksView.swift:87–119`) перестаёт быть белой плиткой и становится
**самостоятельно-тёмным элементом, одинаковым в обеих темах** (как `DarkHeroBackground`),
по образцу NFC-плитки из `design_dark.html`. Использует фиксированные `Color(hex:)`, **не**
адаптивные токены.

- фон: линейный градиент `#171D25 → #232A33` (≈155°);
- inset-тени для «утопленности» + субтильная диагональная штриховка (white α≈0.025);
- глиф бесконтактной оплаты — три дуги цветом `#E6EAF0` (вместо текущего белого фона);
- номер: белый mono (28, bold) с лёгкой тенью;
- **красные полоски убрать** (атрибут светлой отражающей плитки; в чип-карте их нет).

`PhotoTileView` и её `MiniCPBadge` (белый с красной полоской) — без изменений.

## Шаг 2в — удалить `isRecent`-кольцо

Зелёное кольцо `isRecent` убрать из **обеих** плиток и обеих тем:
- удалить `.overlay { if tile.isRecent { Rectangle().strokeBorder(Color.good, ...) } }`
  в `NFCTileView` (`MarksView.swift:114–116`) и `PhotoTileView` (`:155–157`);
- вычистить ставшее мёртвым поле `CheckpointTile.isRecent` (`:10`) и его использование
  в моках (`mockTiles`, `:22`).

## Шаг 3 — проверка

- В каждый `#Preview` добавить вариант `.preferredColorScheme(.dark)` (или second preview),
  чтобы видеть обе темы рядом.
- Собрать и запустить в симуляторе; в Xcode переключать Environment Overrides → Appearance
  (Light/Dark) на каждом из 4 экранов: Отметки, Легенда, Отметить КП (sheet), Команда.
- Свериться визуально с `tmp/design_dark.html` по каждому экрану.
- Проверить, что `grep -rnE "\.white|Color\.black|\.black\.opacity" kolco24/*.swift` не содержит
  оставшихся «поверхностных» литералов (только герой/контент/фиксированный визуал чип-карты).

## Файлы, которые меняются

- `kolco24/DesignTokens.swift` — хелпер + адаптивные токены (Шаг 1)
- `kolco24/SharedComponents.swift`, `LegendView.swift`, `ScanSheet.swift`,
  `TeamView.swift` — замена литералов (Шаг 2)
- `kolco24/MarksView.swift` — замена литералов (Шаг 2), переписать `NFCTileView` в чип-карту
  (Шаг 2б), удалить `isRecent`-кольцо и поле (Шаг 2в)
