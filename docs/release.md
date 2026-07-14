# Релиз в TestFlight — чек-лист ручных шагов

Проект подготовлен к загрузке (этап 11, задача 8): `ITSAppUsesNonExemptEncryption = false`
в `Info.plist`, privacy-манифест `kolco24/PrivacyInfo.xcprivacy`, Release-сборка зелёная.
Ниже — ручные шаги вне кода. Нужен активный аккаунт Apple Developer; записи приложения
в App Store Connect ещё нет.

## 1. Developer Portal — App ID + capability

- Certificates, Identifiers & Profiles → Identifiers → **+** → App IDs → App.
- Bundle ID (explicit): **`kolco24.ru.kolco24`** (совпадает с `PRODUCT_BUNDLE_IDENTIFIER` таргета).
- Capabilities: включить **NFC Tag Reading** (это entitlement на App ID, не только plist-ключ
  `NFCReaderUsageDescription`). Остальные capability не требуются (фоновая геолокация
  и локальная сеть работают через `UIBackgroundModes`/`NSAppTransportSecurity` без entitlement).
- Сохранить.

## 2. App Store Connect — запись приложения

- My Apps → **+** → New App.
- Platform: iOS.
- Name: **Кольцо24** (или согласованное имя; должно быть уникальным в App Store).
- Primary Language: **Russian (ru)**.
- Bundle ID: выбрать зарегистрированный `kolco24.ru.kolco24`.
- SKU: произвольный стабильный идентификатор (например `kolco24-ios`).
- User Access: Full.
- Создать.

## 3. Xcode — подпись

- Target `kolco24` → Signing & Capabilities.
- **Automatically manage signing** — включено.
- **Team** — выбрать команду разработчика (та же, где зарегистрирован App ID).
- Убедиться, что NFC Tag Reading capability подтянулась (или добавить кнопкой **+ Capability**).
- Версия для первой загрузки: `MARKETING_VERSION = 1.0`, `CURRENT_PROJECT_VERSION = 1` — ок.

## 4. Archive → Upload

- Схема `kolco24`, destination **Any iOS Device (arm64)** (не симулятор).
- Product → **Archive**.
- Откроется Organizer → выбрать архив → **Distribute App** →
  **App Store Connect** → **Upload** → пройти шаги подписи → **Upload**.
- Дождаться завершения загрузки; в ASC билд появляется в **TestFlight** после обработки
  (несколько минут — час).

## 5. App Store Connect — App Privacy

- В записи приложения → **App Privacy** → Get Started.
- Заявить сбор пяти типов данных (совпадает с `NSPrivacyCollectedDataTypes` в манифесте):
  - **Precise Location** — запись GPS-трека команды и анти-фрод при взятии КП
    (координата фиксируется в момент отметки).
  - **Photos or Videos** — фото-отметка КП (JPEG-кадры уходят на сервер, когда чип КП сорван/нечитаем).
  - **Email Address** (Contact Info) — email организатора при входе в админ-режим (уходит в теле
    `POST /app/login/` и сохраняется вместе с токеном в Keychain).
  - **Device ID** — `install_id` (сгенерированный приложением UUID установки; уходит в заголовке
    `X-Install-Id` и в теле загрузок `source_install_id` для дедупа на сервере).
  - **User ID** — назначенные идентификаторы участников: номер команды, номера участников,
    NFC-UID браслетов/чипов (уходят с отметками/судейскими сканами).
- Для каждого: Data Use: App Functionality; **Linked to the user** — да (данные связаны с командой/участником);
  Tracking — **нет** (`NSPrivacyTracking = false`, доменов трекинга нет).
- Других типов данных приложение не собирает.
- Сохранить и опубликовать ответы.
- Экспорт-комплаенс: благодаря `ITSAppUsesNonExemptEncryption = false` вопрос при каждой
  загрузке не задаётся (приложение использует только стандартный HTTPS — экземпт).

## 6. Internal Testing

- TestFlight → Internal Testing → **+** рядом с Groups → создать группу
  (например «Организаторы»).
- Добавить тестеров (App Store Connect Users с ролью — до 100 внутренних тестеров,
  без ревью Beta App Review).
- Привязать обработанный билд к группе → тестеры получают приглашение в приложении
  TestFlight.

## 7. Повторные загрузки

- Каждая новая загрузка требует **уникального build-номера**: инкрементировать
  `CURRENT_PROJECT_VERSION` (build number) в настройках таргета перед Archive.
  `MARKETING_VERSION` меняется только при смене версии приложения (1.0 → 1.1 → …).

## Живая верификация на устройстве (после установки через TestFlight)

- Баннер сдвига часов: перевести часы телефона на > 2 мин при выключенной автоустановке →
  после любого запроса к серверу глобальный баннер появляется, «N мин» совпадает;
  вернуть часы → баннер пропадает после следующего якоря.
- NoSync-плашка: свежая установка без сети → открыть скан-оверлей.
- Конфетти + фанфара: полное взятие КП на реальных чипах.
- Иконка приложения в трёх режимах домашнего экрана: Light / Dark / Tinted.
- Провижининг чипов: запись на реальные NTAG213/215/216.
- Smoke-тест основных флоу: выбор команды, отметка КП, фото-отметка, GPS-трек,
  загрузка данных, LAN-режим, админ-режим.
