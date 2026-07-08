//
//  TrackPoint+GRDB.swift
//  kolco24
//
//  GRDB-конформанс доменного типа `TrackPoint` — аналог Room-аннотаций
//  `TrackPointEntity` (PK `id` (TEXT-UUID), индексы по `teamId`/`raceId`).
//  `accuracy`/`verticalAccuracyMeters` — `Float` ↔ REAL, `uploadedLocal`/
//  `uploadedCloud` — Bool ↔ INTEGER. Extension в `Data/`, `Model/` без `import GRDB`.
//

import GRDB

extension TrackPoint: FetchableRecord, PersistableRecord {
    static let databaseTableName = "track_points"

    init(row: Row) {
        self.init(
            id: row["id"],
            raceId: row["raceId"],
            teamId: row["teamId"],
            lat: row["lat"],
            lon: row["lon"],
            accuracy: row["accuracy"],
            altitude: row["altitude"],
            verticalAccuracyMeters: row["verticalAccuracyMeters"],
            gpsTimeMs: row["gpsTimeMs"],
            elapsedRealtimeAt: row["elapsedRealtimeAt"],
            bootCount: row["bootCount"],
            wallMs: row["wallMs"],
            trustedMs: row["trustedMs"],
            segmentId: row["segmentId"],
            uploadedLocal: row["uploadedLocal"],
            uploadedCloud: row["uploadedCloud"]
        )
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["raceId"] = raceId
        container["teamId"] = teamId
        container["lat"] = lat
        container["lon"] = lon
        container["accuracy"] = accuracy
        container["altitude"] = altitude
        container["verticalAccuracyMeters"] = verticalAccuracyMeters
        container["gpsTimeMs"] = gpsTimeMs
        container["elapsedRealtimeAt"] = elapsedRealtimeAt
        container["bootCount"] = bootCount
        container["wallMs"] = wallMs
        container["trustedMs"] = trustedMs
        container["segmentId"] = segmentId
        container["uploadedLocal"] = uploadedLocal
        container["uploadedCloud"] = uploadedCloud
    }
}
