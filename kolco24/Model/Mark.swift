//
//  Mark.swift
//  kolco24
//
//  Доменный тип «взятие КП» (отметка). Зеркало Room-сущности `MarkEntity`
//  (`data/db/MarkEntity.kt`) — локальная запись одного взятия. GRDB-конформанс
//  добавит этап 2.
//
//  Строка создаётся в момент скана чипа КП (чтобы взятие пережило смерть
//  процесса), затем [present] накапливает `numberInTeam` каждого участника,
//  просканированного в скользящем окне. [complete] (= идёт в зачёт) ставится, как
//  только `present` покрыл весь ростер ([expectedCount]).
//

/// Снимок одного участника команды на момент взятия КП — источник для массива
/// `present[]` контракта загрузки. Зеркало `MarkMemberSnapshot`.
struct MarkMemberSnapshot: Equatable {
    let numberInTeam: Int
    let nfcUid: String?
    let number: Int
    let code: String?

    init(numberInTeam: Int, nfcUid: String?, number: Int, code: String? = nil) {
        self.numberInTeam = numberInTeam
        self.nfcUid = nfcUid
        self.number = number
        self.code = code
    }
}

/// Локальная запись одного взятия КП. [id] — сгенерированный клиентом UUID (чтобы
/// два сервера могли сливать базы без коллизий ключей).
struct Mark: Equatable {
    let id: String
    let raceId: Int
    let teamId: Int
    let checkpointId: Int
    let checkpointNumber: Int
    let cost: Int
    let method: String
    let cpUid: String
    let cpCode: String
    let present: [Int]
    let presentDetails: [MarkMemberSnapshot]?
    let expectedCount: Int
    let complete: Bool
    let photoPath: String?
    let takenAt: Int64
    let updatedAt: Int64
    let uploadedLocal: Bool
    let uploadedCloud: Bool
    let photosUploadedLocal: Bool
    let photosUploadedCloud: Bool
    let trustedTakenAt: Int64?
    let elapsedRealtimeAt: Int64?
    let bootCount: Int?
    let locLat: Double?
    let locLon: Double?
    let locAccuracy: Float?
    let locAltitude: Double?
    let locVerticalAccuracy: Float?
    let locGpsTimeMs: Int64?
    let locElapsedRealtimeAt: Int64?

    init(
        id: String,
        raceId: Int,
        teamId: Int,
        checkpointId: Int,
        checkpointNumber: Int,
        cost: Int,
        method: String,
        cpUid: String,
        cpCode: String,
        present: [Int],
        presentDetails: [MarkMemberSnapshot]? = nil,
        expectedCount: Int,
        complete: Bool,
        photoPath: String? = nil,
        takenAt: Int64,
        updatedAt: Int64,
        uploadedLocal: Bool = false,
        uploadedCloud: Bool = false,
        photosUploadedLocal: Bool = false,
        photosUploadedCloud: Bool = false,
        trustedTakenAt: Int64? = nil,
        elapsedRealtimeAt: Int64? = nil,
        bootCount: Int? = nil,
        locLat: Double? = nil,
        locLon: Double? = nil,
        locAccuracy: Float? = nil,
        locAltitude: Double? = nil,
        locVerticalAccuracy: Float? = nil,
        locGpsTimeMs: Int64? = nil,
        locElapsedRealtimeAt: Int64? = nil
    ) {
        self.id = id
        self.raceId = raceId
        self.teamId = teamId
        self.checkpointId = checkpointId
        self.checkpointNumber = checkpointNumber
        self.cost = cost
        self.method = method
        self.cpUid = cpUid
        self.cpCode = cpCode
        self.present = present
        self.presentDetails = presentDetails
        self.expectedCount = expectedCount
        self.complete = complete
        self.photoPath = photoPath
        self.takenAt = takenAt
        self.updatedAt = updatedAt
        self.uploadedLocal = uploadedLocal
        self.uploadedCloud = uploadedCloud
        self.photosUploadedLocal = photosUploadedLocal
        self.photosUploadedCloud = photosUploadedCloud
        self.trustedTakenAt = trustedTakenAt
        self.elapsedRealtimeAt = elapsedRealtimeAt
        self.bootCount = bootCount
        self.locLat = locLat
        self.locLon = locLon
        self.locAccuracy = locAccuracy
        self.locAltitude = locAltitude
        self.locVerticalAccuracy = locVerticalAccuracy
        self.locGpsTimeMs = locGpsTimeMs
        self.locElapsedRealtimeAt = locElapsedRealtimeAt
    }
}
