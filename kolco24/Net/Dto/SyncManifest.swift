//
//  SyncManifest.swift
//  kolco24
//
//  Зеркало `data/api/dto/SyncDtos.kt` 1:1: payload `GET /app/race/<id>/sync/` — lease-манифест
//  локального режима. `versions` сознательно НЕ маппится: клиент не сравнивает версии манифеста
//  (это непрозрачные хэши; пер-origin ETag/304 уже отвечает «изменилось ли»), незнакомые ключи
//  дропаются дефолтом `Codable`. Потребитель-координатор — этап 9.
//

/// Payload `GET /app/race/<id>/sync/`. `leaseTtlSeconds` (относительный) предпочтительнее
/// `leaseExpiresAt` (абсолютные epoch-секунды): свежая установка гоночного дня может иметь холодный
/// `TrustedClock`, а LAN-клиент сознательно без `ServerTimeInterceptor` — потому относительный TTL
/// (считается от момента приёма) иммунен к перекосу часов телефона. Оба поля пока `nil` — бэкенд
/// lease ещё не реализован; парсим, логику lease пока не строим.
struct SyncManifestDto: Codable, Equatable {
    let race: Int
    let dataSource: String
    let leaseTtlSeconds: Int64?
    let leaseExpiresAt: Int64?

    enum CodingKeys: String, CodingKey {
        case race
        case dataSource = "data_source"
        case leaseTtlSeconds = "lease_ttl_seconds"
        case leaseExpiresAt = "lease_expires_at"
    }
}
