//
//  SyncMeta.swift
//  kolco24
//
//  Доменный тип «мета синхронизации». Зеркало Room-сущности `SyncMetaEntity`
//  (`data/db/SyncMetaEntity.kt`) — пер-origin мета синка. GRDB-конформанс
//  — в `Data/Records/SyncMeta+GRDB.swift` (этап 2).
//
//  Композитный ключ `(origin, resource)` держит ETag'и раздельно по origin
//  (base URL) и ресурсу. [etag] хранится дословно (с кавычками) для
//  `If-None-Match`.
//

/// Одна строка меты синхронизации.
struct SyncMeta: Equatable {
    let origin: String
    let resource: String
    let etag: String
}
