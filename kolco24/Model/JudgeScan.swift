//
//  JudgeScan.swift
//  kolco24
//
//  Доменный тип «судейский пик» (**локальный**). Зеркало Room-сущности
//  `JudgeScanEntity` (`data/db/JudgeScanEntity.kt`) — одна судейская отметка
//  старта/финиша: судья на КП тапает браслеты участников, фиксируя время.
//  GRDB-конформанс — в `Data/Records/JudgeScan+GRDB.swift` (этап 2).
//
//  В отличие от `Mark` (скоуп `teamId` + `checkpointId`) судейская станция сканит
//  все команды гонки, поэтому скоуп — [raceId] **только**. Строки **write-once**:
//  ничто не мутирует скан после вставки, каждый пик — новая строка (дедуп на
//  сервере). [id] — сгенерированный клиентом UUID. [eventType] фиксирован по
//  админ-подстранице (`"start"` | `"finish"`). В отличие от `Mark`
//  [elapsedRealtimeAt] здесь **non-null** (сэмпл всегда доступен), [bootCount]
//  остаётся опционален.
//

/// Одна судейская отметка старта/финиша.
struct JudgeScan: Equatable {
    let id: String
    let raceId: Int
    let eventType: String
    let participantNumber: Int
    let nfcUid: String
    let takenAt: Int64
    let trustedTakenAt: Int64?
    let elapsedRealtimeAt: Int64
    let bootCount: Int?
    let sourceInstallId: String
    let uploadedLocal: Bool
    let uploadedCloud: Bool

    init(
        id: String,
        raceId: Int,
        eventType: String,
        participantNumber: Int,
        nfcUid: String,
        takenAt: Int64,
        trustedTakenAt: Int64? = nil,
        elapsedRealtimeAt: Int64,
        bootCount: Int? = nil,
        sourceInstallId: String,
        uploadedLocal: Bool = false,
        uploadedCloud: Bool = false
    ) {
        self.id = id
        self.raceId = raceId
        self.eventType = eventType
        self.participantNumber = participantNumber
        self.nfcUid = nfcUid
        self.takenAt = takenAt
        self.trustedTakenAt = trustedTakenAt
        self.elapsedRealtimeAt = elapsedRealtimeAt
        self.bootCount = bootCount
        self.sourceInstallId = sourceInstallId
        self.uploadedLocal = uploadedLocal
        self.uploadedCloud = uploadedCloud
    }
}
