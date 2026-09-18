//
//  ReadinessChecklist.swift
//  kolco24
//
//  Чистое ядро чек-листа готовности к старту (вкладка «Отметки»). Kotlin-источника нет —
//  iOS-only экран, заменивший урезанную лестницу `MarksEmpty`.
//
//  Вся логика статусов, скрытия пунктов и русских текстов живёт здесь: вьюха ничего не
//  ветвит и не дублирует, а производные шапки (счётчик «N / M», худший статус) считает из
//  самого массива — скрытые пункты меняют его длину.
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

/// Трёхзначный геостатус — в отличие от bool `hasLocationAccess`, который схлопывает
/// `.notDetermined` и `.denied` в `false` и потому всегда выбрасывал бы в Настройки.
enum LocationAuthorization: Equatable {
    case notDetermined
    case denied
    case granted
}

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
    if input.memberCount == 0 || input.boundCount >= input.memberCount {
        return ReadinessItem(
            id: .chips,
            status: .done,
            title: "Чипы привязаны",
            detail: input.memberCount == 0
                ? "В команде нет участников"
                : "\(input.boundCount) из \(input.memberCount)",
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

private func powerItem(_ input: ReadinessInput) -> ReadinessItem? {
    guard input.lowPowerMode else { return nil }
    return ReadinessItem(
        id: .power,
        status: .warning,
        title: "Включено энергосбережение",
        detail: "Фоновая запись трека может прерываться — выключите в Настройках",
        action: .openSettings
    )
}
