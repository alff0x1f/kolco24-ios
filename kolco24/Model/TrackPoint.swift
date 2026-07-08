//
//  TrackPoint.swift
//  kolco24
//
//  Доменный тип «точка GPS-трека» (**локальная**). Зеркало Room-сущности
//  `TrackPointEntity` (`data/db/TrackPointEntity.kt`). GRDB-конформанс добавит
//  этап 2.
//
//  Как и `Mark`, таблица рассчитана на будущую двойную загрузку (local wifi +
//  cloud): [id] — сгенерированный клиентом UUID (идемпотентный merge двух
//  серверов), [uploadedLocal]/[uploadedCloud] — пер-таргетные семена доставки.
//
//  Временные поля привязаны к **моменту фикса**, не доставки: [elapsedRealtimeAt]
//  — монотонный момент захвата и тай-брейкер в пределах загрузки, [trustedMs] —
//  доверенное серверное время (nil при отсутствии синка). [altitude]/
//  [verticalAccuracyMeters] — WGS84-высота и её 1-сигма (nil без верт.-фикса).
//  [wallMs] — обратно-спроецированные стенные часы момента фикса. [bootCount] —
//  boot-сессия [elapsedRealtimeAt]. [segmentId] — UUID сессии записи.
//
//  (Kotlin реализует интерфейс `TrackPointLike`; в Swift-ядре такого протокола
//  нет — Segments-логика чистая и берёт поля напрямую.)
//

/// Одна точка GPS-трека.
struct TrackPoint: Equatable {
    let id: String
    let raceId: Int
    let teamId: Int
    let lat: Double
    let lon: Double
    let accuracy: Float
    let altitude: Double?
    let verticalAccuracyMeters: Float?
    let gpsTimeMs: Int64
    let elapsedRealtimeAt: Int64
    let bootCount: Int?
    let wallMs: Int64
    let trustedMs: Int64?
    let segmentId: String
    let uploadedLocal: Bool
    let uploadedCloud: Bool

    init(
        id: String,
        raceId: Int,
        teamId: Int,
        lat: Double,
        lon: Double,
        accuracy: Float,
        altitude: Double? = nil,
        verticalAccuracyMeters: Float? = nil,
        gpsTimeMs: Int64,
        elapsedRealtimeAt: Int64,
        bootCount: Int? = nil,
        wallMs: Int64,
        trustedMs: Int64? = nil,
        segmentId: String,
        uploadedLocal: Bool = false,
        uploadedCloud: Bool = false
    ) {
        self.id = id
        self.raceId = raceId
        self.teamId = teamId
        self.lat = lat
        self.lon = lon
        self.accuracy = accuracy
        self.altitude = altitude
        self.verticalAccuracyMeters = verticalAccuracyMeters
        self.gpsTimeMs = gpsTimeMs
        self.elapsedRealtimeAt = elapsedRealtimeAt
        self.bootCount = bootCount
        self.wallMs = wallMs
        self.trustedMs = trustedMs
        self.segmentId = segmentId
        self.uploadedLocal = uploadedLocal
        self.uploadedCloud = uploadedCloud
    }
}
