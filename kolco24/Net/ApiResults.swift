//
//  ApiResults.swift
//  kolco24
//
//  Зеркало sealed-типов `FetchResult`/`PostResult` из `data/api/ApiClient.kt`: исход одного
//  сетевого вызова, выраженный значением — ошибки НЕ бросаются, а сворачиваются в кейс.
//  Kotlin `sealed interface` + `data object`/`data class` → Swift `enum` c associated values.
//  `RefreshResult` (исход refresh-репозитория) живёт рядом с репозиториями (задача 5).
//

/// Исход условного GET-запроса, параметризованный распарсенным типом `T`. Сетевые/парс-ошибки
/// сворачиваются в кейс, а не бросаются. Kotlin `FetchResult.NotModified`/`Forbidden` — это
/// `FetchResult<Nothing>`; в Swift кейсы без payload'а просто не несут ассоциированных значений.
enum FetchResult<T> {
    /// `200` — распарсенные данные + ETag ответа (как есть, с кавычками; может быть `nil`).
    case success(data: T, etag: String?)
    /// `304 Not Modified` — сохранённые данные актуальны.
    case notModified
    /// `403 Forbidden` — после 403-retry (для GET) подпись всё равно не принята.
    case forbidden
    /// Прочие коды; `nil` = `URLError` (транспорт) или ошибка парсинга.
    case error(code: Int?)
}

/// Исход одного POST, параметризованный распарсенным типом `T`. Как и `FetchResult`, сетевые и
/// парс-ошибки не бросаются. Асимметрия из Kotlin: `URLError` на POST → `.offline` (офлайн на
/// гонке — ожидаемое состояние для загрузки), тогда как на GET тот же `URLError` → `.error(nil)`.
enum PostResult<T> {
    /// `200`/`201` — распарсенные данные (для пустого тела — `Unit`/`Void` у потребителя).
    case success(T)
    /// `400 Bad Request`.
    case badRequest
    /// `401 Unauthorized` — плохие учётные данные.
    case unauthorized
    /// `403 Forbidden` (POST не ретраится — 403 неразличим auth-vs-skew, replay небезопасен).
    case forbidden
    /// `409 Conflict`.
    case conflict
    /// `429 Too Many Requests`.
    case rateLimited
    /// `URLError` (транспорт) — офлайн.
    case offline
    /// Прочие коды; `nil` = ошибка парсинга.
    case error(code: Int?)
}
