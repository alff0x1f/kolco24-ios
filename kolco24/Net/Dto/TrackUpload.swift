//
//  TrackUpload.swift
//  kolco24
//
//  Зеркало `data/api/dto/TrackDtos.kt` — проводные типы `POST /app/race/<raceId>/track/`.
//  Тело — батч точек GPS-трека одной команды; идемпотентный upsert по клиентскому `TrackPointDto.id`,
//  так что повторная отправка уже принятого батча безопасна.
//
//  **Расхождение с UPLOAD.md:** `TrackUploadRequest` **не** несёт `source_install_id` — текущий
//  Kotlin-клиент его не шлёт (в отличие от marks-контракта), а мы зеркалим клиент, не спеку.
//
//  Nullable-кодирование воспроизводит то, как реально шлёт Android (kotlinx.serialization с
//  `encodeDefaults = false`, `explicitNulls = true`): скаляры **без** default-значения (`altitude`,
//  `vertical_accuracy`, `trusted_ms`, `boot_count`) кодируются явным JSON `null` (ручной `encode`,
//  не `encodeIfPresent`) — отсюда рукописный `encode(to:)` вместо синтезированного.
//
//  **Ловушки маппинга:** `TrackPointDto` дропает локальные `wallMs`/`raceId`/`teamId`/`uploaded*`
//  (гонка/команда — в URL, флаги локальны) и переименовывает `elapsed_at ← elapsedRealtimeAt`,
//  `vertical_accuracy ← verticalAccuracyMeters` — см. `init(from:)`.
//

import Foundation

/// Тело запроса `POST /app/race/<raceId>/track/`. В отличие от marks-загрузки **не** несёт
/// `source_install_id` (зеркало текущего Kotlin-клиента; UPLOAD.md его упоминает — расхождение).
struct TrackUploadRequest: Encodable {
    let teamId: Int
    let points: [TrackPointDto]

    enum CodingKeys: String, CodingKey {
        case teamId = "team_id"
        case points
    }
}

/// Одна точка GPS-трека на проводе. Времена привязаны к **моменту фикса** (см. `TrackPoint`):
/// `segmentId` — id сессии записи (на тап «Начать запись»), по нему сервер группирует, чтобы
/// разрыв stop→start не рисовался одной линией; `trustedMs` — доверенное серверное время (nil без
/// синка); `altitude`/`verticalAccuracyMeters` — WGS84-высота и её оценка (nil без верт.-фикса);
/// `elapsedAt` — монотонный момент захвата; `bootCount` — boot-сессия. Локальный `wallMs`-fallback
/// не выгружается — сервер скорит по `trustedMs`/`gpsTimeMs`.
struct TrackPointDto: Encodable {
    let id: String
    let segmentId: String
    let lat: Double
    let lon: Double
    let accuracy: Float
    let altitude: Double?
    let verticalAccuracyMeters: Float?
    let gpsTimeMs: Int64
    let trustedMs: Int64?
    let elapsedAt: Int64
    let bootCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case segmentId = "segment_id"
        case lat
        case lon
        case accuracy
        case altitude
        case verticalAccuracyMeters = "vertical_accuracy"
        case gpsTimeMs = "gps_time_ms"
        case trustedMs = "trusted_ms"
        case elapsedAt = "elapsed_at"
        case bootCount = "boot_count"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(segmentId, forKey: .segmentId)
        try c.encode(lat, forKey: .lat)
        try c.encode(lon, forKey: .lon)
        try c.encode(accuracy, forKey: .accuracy)
        // No-default nullable-поля: явный JSON null (не encodeIfPresent).
        try c.encode(altitude, forKey: .altitude)
        try c.encode(verticalAccuracyMeters, forKey: .verticalAccuracyMeters)
        try c.encode(gpsTimeMs, forKey: .gpsTimeMs)
        try c.encode(trustedMs, forKey: .trustedMs)
        try c.encode(elapsedAt, forKey: .elapsedAt)
        try c.encode(bootCount, forKey: .bootCount)
    }
}

/// Ответ `POST /app/race/<raceId>/track/`: клиентские `id`, которые сервер принял (upsert'нул).
struct TrackUploadResponse: Decodable, Equatable {
    let accepted: [String]
}

extension TrackPointDto {
    /// Чистый маппер `TrackPoint → TrackPointDto`. Дропает локальные `wallMs`/`raceId`/`teamId`/
    /// `uploaded*` (гонка/команда — в URL/конверте) и несёт fix-моментные времена, по которым скорит
    /// сервер. Зеркало `TrackPointEntity.toDto`.
    init(from point: TrackPoint) {
        self.init(
            id: point.id,
            segmentId: point.segmentId,
            lat: point.lat,
            lon: point.lon,
            accuracy: point.accuracy,
            altitude: point.altitude,
            verticalAccuracyMeters: point.verticalAccuracyMeters,
            gpsTimeMs: point.gpsTimeMs,
            trustedMs: point.trustedMs,
            elapsedAt: point.elapsedRealtimeAt,
            bootCount: point.bootCount
        )
    }
}
