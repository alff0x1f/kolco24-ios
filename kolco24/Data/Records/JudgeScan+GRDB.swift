//
//  JudgeScan+GRDB.swift
//  kolco24
//
//  GRDB-конформанс доменного типа `JudgeScan` — аналог Room-аннотаций
//  `JudgeScanEntity` (PK `id` (TEXT-UUID), индекс по `raceId`, write-once).
//  `elapsedRealtimeAt` здесь non-null (в отличие от `Mark`). Extension в `Data/`,
//  `Model/` без `import GRDB`.
//

import GRDB

extension JudgeScan: FetchableRecord, PersistableRecord {
    static let databaseTableName = "judge_scans"

    init(row: Row) {
        self.init(
            id: row["id"],
            raceId: row["raceId"],
            eventType: row["eventType"],
            participantNumber: row["participantNumber"],
            nfcUid: row["nfcUid"],
            takenAt: row["takenAt"],
            trustedTakenAt: row["trustedTakenAt"],
            elapsedRealtimeAt: row["elapsedRealtimeAt"],
            bootCount: row["bootCount"],
            sourceInstallId: row["sourceInstallId"],
            uploadedLocal: row["uploadedLocal"],
            uploadedCloud: row["uploadedCloud"]
        )
    }

    func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["raceId"] = raceId
        container["eventType"] = eventType
        container["participantNumber"] = participantNumber
        container["nfcUid"] = nfcUid
        container["takenAt"] = takenAt
        container["trustedTakenAt"] = trustedTakenAt
        container["elapsedRealtimeAt"] = elapsedRealtimeAt
        container["bootCount"] = bootCount
        container["sourceInstallId"] = sourceInstallId
        container["uploadedLocal"] = uploadedLocal
        container["uploadedCloud"] = uploadedCloud
    }
}
