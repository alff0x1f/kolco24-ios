//
//  TeamPickerLogic.swift
//  kolco24
//
//  Чистая тестируемая логика экранов выбора гонки/команды. Kotlin-источник:
//  `ui/teampicker/TeamPickerLogic.kt`. Никакого UIKit/SwiftUI — всё юнит-покрыто.
//  Даты сравниваются лексикографически как ISO-строки `yyyy-MM-dd`; `today`
//  всегда приходит строкой. `effectiveEnd` — из `Core/Util/RaceDates.swift`,
//  `pluralRu` — из `Core/Util/PluralRu.swift`.
//

import Foundation

/// Пилюля статуса в строке гонки. Несёт только подпись; маппинг цвета — во вьюхе.
enum RaceStatusPill: String {
    case finished
    case registration
    case upcoming

    /// Русская подпись пилюли.
    var label: String {
        switch self {
        case .finished: return "Завершено"
        case .registration: return "Регистрация"
        case .upcoming: return "Скоро"
        }
    }
}

/// Гонки, разбитые на текущие (ещё релевантны) и архив (уже завершены),
/// с сохранением порядка (как пришли — новые первыми).
struct SplitRaces: Equatable {
    let current: [Race]
    let archive: [Race]
}

/// Пилюля статуса для гонки: завершена, если последний день раньше `today`;
/// иначе — по `regStatus` (`open` → регистрация, всё остальное → скоро).
/// Состояние регистрации тут неважно — экран для выбора своей команды, не для
/// записи — поэтому `sold_out` не получает бейджа «Мест нет» и читается как
/// [RaceStatusPill.upcoming], как любая другая текущая гонка.
func raceStatusPill(_ race: Race, today: String) -> RaceStatusPill {
    if effectiveEnd(race) < today { return .finished }
    switch race.regStatus {
    case "open": return .registration
    default: return .upcoming
    }
}

/// Разбить `races` на текущие (`effectiveEnd >= today`) и архив (уже прошли),
/// сохраняя порядок исходного списка (новые первыми).
func splitRaces(_ races: [Race], today: String) -> SplitRaces {
    let current = races.filter { effectiveEnd($0) >= today }
    let archive = races.filter { effectiveEnd($0) < today }
    return SplitRaces(current: current, archive: archive)
}

/// Команды, у которых `teamname` или `startNumber` содержат `query`
/// (регистронезависимый подстрочный поиск). Пустой запрос возвращает все.
func filterTeams(_ teams: [Team], query: String) -> [Team] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if needle.isEmpty { return teams }
    let lower = needle.lowercased()
    return teams.filter { team in
        team.teamname.lowercased().contains(lower)
            || (team.startNumber?.lowercased().contains(lower) ?? false)
    }
}

/// Строка «Категория X · N человек/человека». На герой-карточке и в подтверждении.
func peopleLine(category: Category?, ucount: Int) -> String {
    let cat = category?.shortName.nonBlank ?? category?.name.nonBlank
    let word = peopleWord(ucount)
    if let cat { return "Категория \(cat) · \(ucount) \(word)" }
    return "\(ucount) \(word)"
}

/// Русское склонение «человек»: «человека» для 2–4 (не 12–14), иначе «человек».
func peopleWord(_ n: Int) -> String {
    pluralRu(count: n, one: "человек", few: "человека", many: "человек")
}

/// Короткий текст токена команды: стартовый номер, если есть, иначе монограмма
/// из названия. Пустой стартовый номер (Django `default=""`) считается «без номера».
func teamToken(_ team: Team) -> String {
    if let number = team.startNumber, !number.isBlank {
        return number
    }
    let mono = initials(team.teamname)
    return mono.isEmpty ? "#\(team.id)" : mono
}

/// Читаемое имя команды для списка, шита и герой-карточки. Фолбэк, когда
/// `teamname` пуст (`blank=True` в модели): «Команда <start_number>», если номер
/// есть, иначе «Команда #<id>».
func displayTeamName(_ team: Team) -> String {
    if !team.teamname.isBlank { return team.teamname }
    if let number = team.startNumber, !number.isBlank {
        return "Команда \(number)"
    }
    return "Команда #\(team.id)"
}

/// Монограмма из `text`: первая буква до `max` слов, в верхнем регистре.
/// Разделяет фолбэк-токен команды и инициалы аватара участника. Пустой ввод → "".
func initials(_ text: String, max: Int = 2) -> String {
    text.split(separator: " ", omittingEmptySubsequences: true)
        .prefix(max)
        .compactMap { $0.first?.uppercased() }
        .joined()
}

private extension String {
    /// `true`, если строка пуста или состоит только из пробельных символов.
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Сама строка, если не blank, иначе `nil` (аналог `takeIf { it.isNotBlank() }`).
    var nonBlank: String? {
        isBlank ? nil : self
    }
}
