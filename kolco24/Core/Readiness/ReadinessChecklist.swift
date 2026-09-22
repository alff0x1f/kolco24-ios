//
//  ReadinessChecklist.swift
//  kolco24
//
//  Чистое ядро чек-листа готовности к старту (вкладка «Отметки»). Kotlin-источника нет —
//  iOS-only экран, заменивший урезанную лестницу `MarksEmpty`.
//
//  Вся логика статусов, скрытия пунктов и русских текстов живёт здесь: вьюха ничего не
//  ветвит и не дублирует, а производные шапки (счётчик «N / M», худший статус) считает из
//  самого массива — скрытые пункты меняют его длину. Единственное исключение — свёрнутая
//  строка полной готовности (`ReadinessCard.readyRow`): у неё нет своего `ReadinessItemId`,
//  поэтому её текст остался во вьюхе.
//
//  Порядок пунктов фиксирован и **не** сортируется по статусу: прыгающие строки хуже одного
//  пункта ниже по списку.
//
//  Foundation-only (греп-инвариант `Core/`).
//

import Foundation

/// Тяжесть пункта чек-листа.
enum ReadinessStatus: Equatable {
    /// Пункт выполнен.
    case done
    /// Отметиться можно, но качество данных страдает (гео, легенда, карта, часы, энергосбережение).
    case warning
    /// Без этого отметка физически не сработает (команда, чипы).
    case blocked
}

/// Идентификатор пункта — он же ключ порядка и `Identifiable.id` во вьюхе.
enum ReadinessItemId: Equatable {
    case team
    case chips
    case location
    case legend
    case map
    case clock
    case power
}

/// Действие по тапу на строку. `nil` в `ReadinessItem.action` — строка без стрелки и без кнопки.
enum ReadinessAction: Equatable {
    /// Открыть выбор соревнования и команды.
    case chooseTeam
    /// Перейти на вкладку «Команда» к привязке чипов.
    case bindChips
    /// Системный диалог геодоступа (только при `.notDetermined`).
    case requestLocation
    /// Настройки iOS (отказ в геодоступе, приблизительная точность, Low Power Mode).
    case openSettings
    /// Ручное обновление данных с сервера.
    case refresh
    /// Перейти на вкладку «Карта».
    case openMap
}

/// Одна строка чек-листа.
struct ReadinessItem: Equatable, Identifiable {
    let id: ReadinessItemId
    let status: ReadinessStatus
    let title: String
    let detail: String
    let action: ReadinessAction?
}

/// Доступность оффлайн-подложки для чек-листа — read-only срез `MapAvailability`
/// (без состояний скачивания: CTA ведёт на вкладку «Карта», где весь UI прогресса уже есть).
enum MapReadiness: Equatable {
    /// У гонки нет `mapUrl` — пункт карты в чек-лист не попадает вовсе.
    case notApplicable
    case missing
    case ready
}

// `LocationAuthorization` (вход строки геодоступа) живёт в `Core/Track/CurrentLocation` —
// это общий тип платформенной способности, а не часть чек-листа: его отдаёт `Location/`.

/// Снимок входов чек-листа: всё, что нужно для построения массива.
struct ReadinessInput {
    let hasTeam: Bool
    /// `Team.teamname` для detail строки команды; пустая строка, если команды нет.
    let teamTitle: String
    let memberCount: Int
    let boundCount: Int
    let locationAuthorization: LocationAuthorization
    let isReducedAccuracy: Bool
    let checkpointCount: Int
    let map: MapReadiness
    let clock: ClockStatus
    let lowPowerMode: Bool
}

/// Построить чек-лист готовности из снимка входов.
///
/// Скрытие пунктов: `map == .notApplicable` (у гонки нет подложки — иначе чек-лист вечно
/// неполный) и `lowPowerMode == false` (галочка «энергосбережение выключено» не несёт
/// информации) не попадают в массив. Остальные пункты присутствуют всегда, включая `chips`
/// и `location` при `hasTeam == false` — длина списка стабильна внутри одного состояния
/// выбора.
func readinessItems(_ input: ReadinessInput) -> [ReadinessItem] {
    var items: [ReadinessItem] = []

    items.append(teamItem(input))
    items.append(chipsItem(input))
    items.append(locationItem(input))
    items.append(legendItem(input))
    if let map = mapItem(input) { items.append(map) }
    items.append(clockItem(input))
    if let power = powerItem(input) { items.append(power) }

    return items
}

// MARK: - Пункты

private func teamItem(_ input: ReadinessInput) -> ReadinessItem {
    if input.hasTeam {
        return ReadinessItem(
            id: .team,
            status: .done,
            title: "Команда выбрана",
            detail: input.teamTitle,
            action: .chooseTeam
        )
    }
    return ReadinessItem(
        id: .team,
        status: .blocked,
        title: "Команда не выбрана",
        detail: "Выберите соревнование и команду",
        action: .chooseTeam
    )
}

private func chipsItem(_ input: ReadinessInput) -> ReadinessItem {
    guard input.hasTeam else {
        return ReadinessItem(
            id: .chips,
            status: .blocked,
            title: "Чипы не привязаны",
            detail: "Сначала выберите команду",
            action: nil
        )
    }
    // Пустой ростер — НЕ «готово»: `ScanModel.process` жёстко отбивает скан при пустом составе
    // («команда не выбрана»), так что зелёная галочка здесь обещала бы невозможное.
    guard input.memberCount > 0 else {
        return ReadinessItem(
            id: .chips,
            status: .blocked,
            title: "Состав команды не загружен",
            detail: "Без участников отметка не сработает — обновите данные",
            action: .refresh
        )
    }
    if input.boundCount >= input.memberCount {
        return ReadinessItem(
            id: .chips,
            status: .done,
            title: "Чипы привязаны",
            detail: "\(input.boundCount) из \(input.memberCount)",
            action: .bindChips
        )
    }
    return ReadinessItem(
        id: .chips,
        status: .blocked,
        title: "Чипы привязаны не всем",
        detail: "\(input.boundCount) из \(input.memberCount)",
        action: .bindChips
    )
}

private func locationItem(_ input: ReadinessInput) -> ReadinessItem {
    switch input.locationAuthorization {
    case .notDetermined:
        return ReadinessItem(
            id: .location,
            status: .warning,
            title: "Геолокация",
            detail: "Доступ не запрошен — нажмите, чтобы разрешить",
            action: .requestLocation
        )
    case .denied:
        return ReadinessItem(
            id: .location,
            status: .warning,
            title: "Геолокация",
            detail: "Доступ запрещён — включите в Настройках",
            action: .openSettings
        )
    case .granted:
        if input.isReducedAccuracy {
            return ReadinessItem(
                id: .location,
                status: .warning,
                title: "Геолокация",
                detail: "Дана примерная локация — включите точную геопозицию",
                action: .openSettings
            )
        }
        return ReadinessItem(
            id: .location,
            status: .done,
            title: "Геолокация разрешена",
            detail: "Точная геопозиция",
            action: nil
        )
    }
}

private func legendItem(_ input: ReadinessInput) -> ReadinessItem {
    if input.checkpointCount > 0 {
        return ReadinessItem(
            id: .legend,
            status: .done,
            title: "Легенда загружена",
            detail: "\(input.checkpointCount) КП",
            action: nil
        )
    }
    return ReadinessItem(
        id: .legend,
        status: .warning,
        title: "Легенда не загружена",
        detail: "Нажмите, чтобы обновить данные",
        action: .refresh
    )
}

private func mapItem(_ input: ReadinessInput) -> ReadinessItem? {
    switch input.map {
    case .notApplicable:
        return nil
    case .ready:
        return ReadinessItem(
            id: .map,
            status: .done,
            title: "Карта скачана",
            detail: "Подложка доступна оффлайн",
            action: .openMap
        )
    case .missing:
        return ReadinessItem(
            id: .map,
            status: .warning,
            title: "Карта не скачана",
            detail: "Скачайте подложку заранее — в лесу может не быть связи",
            action: .openMap
        )
    }
}

private func clockItem(_ input: ReadinessInput) -> ReadinessItem {
    switch input.clock {
    case .ok:
        return ReadinessItem(
            id: .clock,
            status: .done,
            title: "Часы синхронизированы",
            detail: "Время совпадает с судейским",
            action: nil
        )
    case .noSync:
        return ReadinessItem(
            id: .clock,
            status: .warning,
            title: "Часы не синхронизированы",
            detail: "Нет связи с сервером — время отметок берётся с телефона",
            action: nil
        )
    case .skewed(let skewMs):
        return ReadinessItem(
            id: .clock,
            status: .warning,
            title: "Часы расходятся",
            detail: "Расхождение с судейским временем — \(formatSkewMinutes(skewMs))",
            action: nil
        )
    }
}

// Действия нет намеренно: `app-settings:` открывает страницу САМОГО приложения (геодоступ, камера),
// а Low Power Mode живёт в Настройках → Аккумулятор, куда публичного URL у iOS нет. Стрелка вела бы
// в тупик, поэтому пункт информационный — как `clock`, — а путь назван прямо в detail.
private func powerItem(_ input: ReadinessInput) -> ReadinessItem? {
    guard input.lowPowerMode else { return nil }
    return ReadinessItem(
        id: .power,
        status: .warning,
        title: "Включено энергосбережение",
        detail: "Фоновая запись трека может прерываться — выключите в Настройках → Аккумулятор",
        action: nil
    )
}

// MARK: - Производные шапки карточки

/// Сводка по массиву для шапки: счётчик «N / M», худший статус (цвет точки и полоски) и признак
/// полной готовности (карточка сворачивается в одну зелёную строку). Живёт здесь, а не во вьюхе:
/// это логика (приоритет `blocked` > `warning` > `done`), а не вёрстка, и она покрывается таблицей.
struct ReadinessSummary: Equatable {
    let done: Int
    let total: Int
    let worst: ReadinessStatus
    let allDone: Bool
}

func readinessSummary(_ items: [ReadinessItem]) -> ReadinessSummary {
    let done = items.filter { $0.status == .done }.count
    let worst: ReadinessStatus
    if items.contains(where: { $0.status == .blocked }) {
        worst = .blocked
    } else if items.contains(where: { $0.status == .warning }) {
        worst = .warning
    } else {
        worst = .done
    }
    return ReadinessSummary(
        done: done,
        total: items.count,
        worst: worst,
        // Пустой массив — не «всё готово»: сворачивать в зелёную строку нечего.
        allDone: !items.isEmpty && done == items.count
    )
}

// MARK: - Гейт первой отрисовки

/// Можно ли уже рисовать карточку. Карточка читает ПЯТЬ независимых асинхронных источников: три
/// observation'а (взятия, привязки, КП гонки), синхронный опрос устройства и одиночное чтение
/// `races.map_url` из БД. Порядка между ними нет, поэтому гейт по части источников пропускал бы кадр
/// с неполным снимком — красное «Чипы привязаны не всем · 0 из N» у полностью привязанной команды или
/// ложно-зелёное «Всё готово к старту», которое через миг разворачивается строкой «Карта не скачана».
/// Чистая функция (а не `if` в модели), чтобы проверяться таблицей: каждый «ещё не пришёл» по
/// отдельности обязан прятать карточку.
func readinessCardVisible(
    marksLoading: Bool,
    bindingsLoading: Bool,
    checkpointsLoading: Bool,
    deviceStatePolled: Bool,
    mapUrlResolved: Bool
) -> Bool {
    !marksLoading && !bindingsLoading && !checkpointsLoading && deviceStatePolled && mapUrlResolved
}
