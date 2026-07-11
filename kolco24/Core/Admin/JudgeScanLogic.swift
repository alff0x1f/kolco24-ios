//
//  JudgeScanLogic.swift
//  kolco24
//
//  Чистая логика судейского скана старта/финиша. Порт `ui/admin/JudgeScanModel.kt`
//  (`classifyJudgeScan` :52) + конструирующей половины `JudgeScanRepository.record`
//  (:65). Хост (`JudgeScanModel`, Task 8) владеет NFC-хуком и «грязными» чтениями
//  (`observeForRace`-пул, `readChipCode`, флаг «пул хоть раз синхронился»); здесь —
//  только решение по уже-разрешённым значениям и сборка write-once строки.
//
//  `Core/Admin/` — Foundation-only (grep-инвариант этапа 9/10): без сети/GRDB/UI.
//

import Foundation

/// Итог одного судейского пика против пула `member_tags` текущей гонки.
///
/// - `recorded` — UID есть в пуле; строку следует записать. **Только эта ветка пишет.**
/// - `unknownChip` — UID не в пуле и `K24`-кода нет: чужая карта, чистый чип или устаревший пул.
/// - `kpChip` — UID не в пуле, но прочитан `K24`-код: судья тапнул чип КП вместо браслета.
/// - `poolNotReady` — пул `member_tags` гонки ещё не синхронизирован; скан отклоняется целиком,
///   независимо от того, что UID мог бы сматчить.
enum JudgeScanResult: Equatable {
    case poolNotReady
    case recorded(uid: String, number: Int)
    case kpChip
    case unknownChip(uid: String)
}

/// Решает итог судейского скана по уже-разрешённым хостом значениям. Чисто — без I/O, без Flow.
///
/// - Parameters:
///   - uid: нормализованный UID отсканированного чипа.
///   - memberNumber: номер участника из `pool.first { $0.nfcUid == uid }?.number` — `nil`, когда
///     UID не в пуле; консультируется только при [poolReady].
///   - hasKpCode: вернул ли `readChipCode` код для этого чипа; консультируется только на ветке
///     «не в пуле».
///   - poolReady: синхронизирован ли пул `member_tags` гонки; проверяется **первым** — скан при
///     несинхронизированном пуле отклоняется, даже когда [memberNumber] мог бы сматчить.
///
/// Порядок веток 1:1 с Kotlin (это спецификация): `!poolReady` → [poolNotReady];
/// `memberNumber != nil` → [recorded]; `hasKpCode` → [kpChip]; иначе → [unknownChip].
func classifyJudgeScan(
    uid: String,
    memberNumber: Int?,
    hasKpCode: Bool,
    poolReady: Bool
) -> JudgeScanResult {
    if !poolReady {
        return .poolNotReady
    }
    if let number = memberNumber {
        return .recorded(uid: uid, number: number)
    }
    if hasKpCode {
        return .kpChip
    }
    return .unknownChip(uid: uid)
}

/// Собрать write-once строку судейского скана из семпла времени. Порт конструирующей половины
/// `JudgeScanRepository.record` (:65) по идиоме `makeKpTakeMark`: UUID [id] и [sample] передаются
/// параметрами (детерминизм/чистота — персист делает вызывающий через `judgeScanStore.insert`).
/// `takenAt = sample.wallMs`; `trustedTakenAt`/`elapsedRealtimeAt`/`bootCount` — из того же
/// [sample]; upload-флаги остаются `false` (write-once, дренится позже).
func makeJudgeScan(
    id: String,
    raceId: Int,
    eventType: String,
    participantNumber: Int,
    nfcUid: String,
    sample: TimeSample,
    sourceInstallId: String
) -> JudgeScan {
    JudgeScan(
        id: id,
        raceId: raceId,
        eventType: eventType,
        participantNumber: participantNumber,
        nfcUid: nfcUid,
        takenAt: sample.wallMs,
        trustedTakenAt: sample.trustedMs,
        elapsedRealtimeAt: sample.elapsedMs,
        bootCount: sample.bootCount,
        sourceInstallId: sourceInstallId
    )
}
