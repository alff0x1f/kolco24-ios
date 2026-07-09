//
//  RaceDates.swift
//  kolco24
//
//  Чистые Android-free хелперы дат гонок. Kotlin-источник:
//  `data/DateUtils.kt` (`todayIso`, `effectiveEnd`, `nearestRaceId`).
//
//  Даты сравниваются **лексикографически как ISO-строки** (`yyyy-MM-dd`
//  сортируется как текст) — ровно как в Kotlin, где `java.time.LocalDate`
//  сознательно избегают (нужен API 26+). Поле `date` — старт гонки, `dateEnd`
//  опционален.
//

import Foundation

/// Сегодняшняя дата строкой `yyyy-MM-dd`. В чистой функции текущий момент
/// приходит параметром (`now`, по умолчанию `Date()`), без скрытого `Date()`
/// внутри логики. Формат — локальная календарная дата, Locale US.
func todayIso(now: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: now)
}

/// Последний релевантный день гонки: `dateEnd`, если задан, иначе старт `date`.
/// Порт Kotlin-расширения `RaceEntity.effectiveEnd()` (`dateEnd ?: date`).
func effectiveEnd(_ race: Race) -> String {
    race.dateEnd ?? race.date
}

/// Id ближайшей по старту текущей гонки; `nil`, когда текущих нет.
/// «Текущая» = `effectiveEnd >= today` (ещё релевантна, как в `splitRaces`);
/// среди них выбирается с самым ранним стартом `date` (лексикографическое ISO
/// сравнение). Используется для прогрева кэша команд/легенды на старте;
/// офлайн/пусто → `nil` → no-op.
func nearestRaceId(_ races: [Race], today: String) -> Int? {
    races
        .filter { effectiveEnd($0) >= today }
        .min { $0.date < $1.date }?
        .id
}
