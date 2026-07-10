# План портирования Android-приложения kolco24 на iOS

## Контекст

iOS-приложение (`kolco24_ios`) сейчас — это UI-скелет: 3 вкладки (Отметки, Легенда, Команда) на SwiftUI с готовой дизайн-системой (DesignTokens, адаптивная светлая/тёмная тема), но все данные — локальные мок-массивы, без сети, БД и NFC.

Android-приложение (`kolco24_app_v2`) — полнофункциональное: ~122 Kotlin-файла, Room v5 (13 таблиц), подписанный HMAC API (облако + LAN-сервер), NFC-отметки на КП, привязка браслетов, фото-отметки (CameraX), фоновая запись GPS-трека, оффлайн-крипто легенды (AES-GCM/HKDF), админ-режим (провижининг чипов, судейские сканы), dual-target загрузка данных.

Ключевое преимущество для порта: в Android чистая логика намеренно отделена от платформенных адаптеров и покрыта JVM-тестами — её можно переносить 1:1 вместе с тестами. Контракт сервера фиксирован (подпись, ETag, идемпотентность, формат крипто-легенды) — его надо воспроизвести байт-в-байт.

## Этапы (в порядке выполнения)

### Этап 0. Инфраструктура проекта

✅ выполнен — см. [детальный план](completed/20260708-android-port-stage0.md).

- Секреты: `API_BASE_URL` / `APP_KEY_ID` / `APP_SECRET` / `LOCAL_API_BASE_URL` через `.xcconfig` (не в git) → Info.plist, по аналогии с `local.properties` в Android.
- Зависимости: GRDB (SQLite, аналог Room). Остальное — системные фреймворки (CryptoKit, CoreNFC, CoreLocation, AVFoundation).
- Тестовый таргет для переносимых unit-тестов.
- ATS-исключение для cleartext LAN-хоста (аналог `network_security_config.xml`).

### Этап 1. Чистая логика (порт 1:1 + тесты)

✅ выполнен — см. [детальный план](completed/20260708-android-port-stage1.md).

Всё Android-free и уже протестировано в Kotlin — переносится напрямую, тесты зеркалируются:
- `LegendCrypto` → CryptoKit (bid = sha256[:16], HKDF-SHA256 c нулевой солью, AES-256-GCM с AAD; сверить с Python-референсом сервера).
- HMAC-подпись запросов (`buildCanonical`/`sign`) и `TrustedClock` (доверенное время: серверный якорь + монотонные часы).
- `ScanSession`/`classifyTag` (state machine 20-секундного окна сканирования), `decideBind`, `decidePhotoTarget`, `nextSegmentId`/`shouldLiveUpload`, парсинг/сборка формата чипа `K24`, `normalizeNfcUid`, `pluralRu`.

### Этап 2. Данные: БД и хранилища

✅ выполнен — см. [детальный план](completed/20260709-android-port-stage2.md).

- Схема GRDB, зеркалящая Room v5: races, categories, teams, selected_team, checkpoints, tags, member_tags, member_chip_bindings, marks (самая богатая — UUID, снапшоты участников, trusted-время, GPS-поля), track_points, judge_scans, sync_meta (ETags), legend_meta.
- UserDefaults-хранилища: `InstallId`, `ClockAnchorStore` + `TrustedClock.makeDefault()`. `ThemePreference`/`TrackProfilePreference` и Keychain-`AdminTokenStore` отложены (этапы 8–10).

### Этап 3. Сеть и синхронизация

✅ выполнен — см. [детальный план](completed/20260709-android-port-stage3.md).

- `ApiClient` на URLSession: подпись 6 заголовками (`X-App-Platform: ios`), `ServerTimeInterceptor` (якорь TrustedClock по заголовку Date), retry-once на 403 для GET.
- Условные GET с ETag/304 и типы `FetchResult`/`PostResult` (ошибки не бросаются).
- 4 sync-репозитория: Race/Team/Legend/MemberTags (паттерн «persist → потом ETag»), `LegendRepository.unlock` поверх крипто из этапа 1.
- LAN-режим (lease/pin, `SyncCoordinator`) — заложить `SyncSource` в API репозиториев сразу, полную реализацию можно отложить на этап 9.

### Этап 4. Подключение существующего UI к реальным данным

✅ выполнен — см. [детальный план](completed/20260709-android-port-stage4.md).

- Заменить мок-массивы: выбор гонки/команды (CompPicker → TeamPicker → подтверждение), Команда (ростер, привязки), Легенда (реальные КП, locked-состояния, ScoreCard, pull-to-refresh), Отметки (реальные взятия, метрики).
- Пустые состояния («выбери команду», «привяжи чипы»).

### Этап 5. NFC-отметка на КП (ядро приложения)

✅ выполнен — см. [детальный план](completed/20260709-android-port-stage5.md).

- CoreNFC `NFCTagReaderSession` + `sendMiFareCommand` (FAST_READ/READ, GET_VERSION) — порт `MifareUltralightWriter` в read-части.
- **Ключевое отличие платформы:** на iOS нет постоянного reader-mode — сессия запускается пользователем, живёт ~60 с и показывает системную шторку. UX скан-оверлея придётся адаптировать (кнопка «Сканировать» вместо «просто приложи»), 20-секундное окно `ScanSession` — внутри сессии.
- Персист взятий (порт state machine `ScanTakeState` из MainActivity — самая сложная часть порта), one-shot GPS-фикс на момент взятия (анти-фрод), звук/вибро-фидбек (AVAudioPlayer + CoreHaptics, перенести WAV-ассеты).
- Привязка браслета (BindChipSheet, чтение UID + пул member_tags).

### Этап 6. Загрузка данных на сервер

✅ выполнен — см. [детальный план](completed/20260710-android-port-stage6.md).

- Dual-target (облако + LAN) идемпотентный upload: marks (батчи, UUID), track, judge_scans; мьютекс-защита, батч-дренаж.
- Триггеры: foreground-таймеры (5 мин / 60 с), по закрытию скан-оверлея, при старте. Фоновые лимиты iOS: опционально BGTaskScheduler позже.
- Экран «Загрузка данных» (счётчики по целям, принудительный flush).

### Этап 7. Фото-отметка

✅ выполнен — см. [детальный план](completed/20260710-android-port-stage7.md).

- AVFoundation-камера (порт PhotoCaptureScreen, но ориентация — через `AVCaptureDevice.RotationCoordinator`, а не акселерометр; EXIF запекается ImageIO), `PhotoStorage` в Application Support (относительные пути в БД), PhotoNumberPicker / авто-привязка к недавнему взятию, лайтбокс, покадровая идемпотентная загрузка (poison-frame 400/413), sweep осиротевших папок.

### Этап 8. GPS-трек
- `CLLocationManager` с background mode «location» (аналог foreground-service): профили Precise/Economy, сегменты, lossless-стоп, live-upload раз в ~10 мин, TrackCard в Команде, GPX-экспорт через share sheet.

### Этап 9. LAN-режим и настройки
- Полный local-mode: `/sync/`-манифест, lease на 12 ч, переключение источников, экран настроек (тема, GPS-профиль, LAN, очистка трека, скрытая отладка).

### Этап 10. Админ-режим
- Логин (bearer, Keychain), судейский скан старт/финиш, проверка КП-чипа и браслета (read-only).
- Провижининг (запись чипов через `sendMiFareCommand` WRITE 0xA2, header-last commit) — **самая рискованная фича**: делать последней, проверить на реальных NTAG213/215/216.

### Этап 11. Полировка
- Баннер сдвига часов (TrustedClock.Skewed), празднования взятий, тёмная тема для новых экранов, иконка, TestFlight.

## Принципы
- После этапов 3–5 приложение уже полезно участнику на гонке (легенда + отметки локально); загрузка (этап 6) делает его боевым — это MVP-граница.
- Каждый чистый модуль этапа 1 переносится вместе со своими тестами — это спецификация поведения.
- Источник правды по контракту API: `kolco24_app_v2/docs/design/API.md`, `docs/design/UPLOAD.md`.
- Эндпоинт judge_scans на сервере ещё не реализован — на iOS ряды просто останутся pending, как и на Android.

## Верификация
- Порт-тесты этапа 1 — прогонять против тех же векторов, что в Kotlin (особенно LegendCrypto и подпись HMAC — сверка с реальным сервером: подписанный GET `/app/races/` должен вернуть 200).
- Сквозная проверка на устройстве (NFC и GPS не работают в симуляторе): скан реального чипа → взятие в БД → появление на сервере.
