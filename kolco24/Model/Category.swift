//
//  Category.swift
//  kolco24
//
//  Доменный тип «категория гонки» (дистанция/группа). Зеркало Room-сущности
//  `CategoryEntity` (`data/db/CategoryEntity.kt`) — зеркало `CategoryDto`.
//  GRDB-конформанс добавит этап 2.
//
//  Принадлежит гонке через [raceId]. Серверное поле `order` — зарезервированное
//  SQL-слово, поэтому колонка называется [sortOrder].
//

/// Одна категория гонки. Первичный ключ [id] — серверный id.
struct Category: Equatable {
    let id: Int
    let raceId: Int
    let code: String
    let shortName: String
    let name: String
    let sortOrder: Int
}
