//
//  ChipCheckLogic.swift
//  kolco24
//
//  Чистая логика двух read-only проверок чипов админ-режима (этап 10). Порт `ui/admin/ChipCheckModel.kt`
//  (`classifyChipCheck` :101, `changedNibbles` :86) + `ui/admin/MemberChipCheckModel.kt` (:64). Хосты
//  (`ChipCheckModel`/`MemberChipCheckModel`, App-слой) владеют NFC-хуком и «грязными» чтениями
//  (подписки `observeTagsForRace`/`observeCheckpointsForRace`/`observeForRace`, `LegendCrypto.bid`);
//  здесь — только решение по уже-разрешённым значениям.
//
//  Полностью оффлайн, identity-only: КП-чип верифицируется матчем производного `bid` против
//  синхронизированной легенды (`Tag`/`Checkpoint`), браслет — матчем UID против пула `member_tags`.
//  Никакой дешифровки, никакого `reveal`-сайд-эффекта, никакого сетевого раунд-трипа.
//
//  `Core/Admin/` — Foundation-only (grep-инвариант этапа 9/10): без сети/GRDB/UI.
//

import Foundation

// MARK: - Проверка чипа КП

/// Итог верификации одного КП-чипа против легенды текущей гонки.
///
/// - `ok` — `bid` чипа сматчил тег, чей КП существует в легенде.
/// - `unknownChip` — код прочитан, но тега с таким `bid` в гонке нет (чужая гонка или устаревший список).
/// - `inconsistent` — тег по `bid` найден, но его [checkpointId] не имеет строки КП (дрейф легенды).
/// - `noCode` — `readChipCode` вернул `nil`: чистый чип, браслет или ошибка чтения (различить нельзя).
enum ChipCheckResult: Equatable {
    /// Чип корректно привязан к существующему КП.
    case ok(uid: String, number: Int, cost: Int?, color: CheckpointColor?, bid: String, checkMethod: String, chipsOnKp: Int)
    /// Код прочитан, но тега с этим [bid] в гонке нет.
    case unknownChip(uid: String, bid: String)
    /// Тег по [bid] найден, но его [checkpointId] не имеет строки КП в легенде.
    case inconsistent(uid: String, bid: String, checkpointId: Int)
    /// Кода КП с чипа не прочитано (чистый чип, браслет или ошибка чтения).
    case noCode(uid: String)

    /// Нормализованный UID (uppercase hex) отсканированного чипа — присутствует в каждом варианте.
    var uid: String {
        switch self {
        case let .ok(uid, _, _, _, _, _, _): return uid
        case let .unknownChip(uid, _): return uid
        case let .inconsistent(uid, _, _): return uid
        case let .noCode(uid): return uid
        }
    }
}

/// Решает итог верификации КП-чипа по уже-разрешённым хостом значениям. Чисто — без I/O, без Flow.
///
/// - Parameters:
///   - uid: нормализованный UID отсканированного чипа.
///   - bid: производный `bid` чипа, или `nil`, когда код не прочитан.
///   - tag: `tags.first { $0.bid == bid }` — `nil`, когда тег не сматчил.
///   - checkpoint: `checkpointsById[tag.checkpointId]` — `nil`, когда КП тега нет в легенде.
///   - chipsOnKp: сколько тегов у легенды для КП сматченного тега; значимо только на ветке [ok].
///
/// Порядок веток 1:1 с Kotlin (это спецификация): `bid == nil` → [noCode]; `tag == nil` →
/// [unknownChip]; `checkpoint == nil` → [inconsistent]; иначе → [ok].
func classifyChipCheck(
    uid: String,
    bid: String?,
    tag: Tag?,
    checkpoint: Checkpoint?,
    chipsOnKp: Int
) -> ChipCheckResult {
    guard let bid else { return .noCode(uid: uid) }
    guard let tag else { return .unknownChip(uid: uid, bid: bid) }
    guard let checkpoint else {
        return .inconsistent(uid: uid, bid: bid, checkpointId: tag.checkpointId)
    }
    return .ok(
        uid: uid,
        number: checkpoint.number,
        cost: checkpoint.cost,
        color: parseCheckpointColor(checkpoint.color),
        bid: bid,
        checkMethod: tag.checkMethod,
        chipsOnKp: chipsOnKp
    )
}

/// Позиции в [uid], чей hex-nibble отличается от [previous] на том же индексе — цифры, изменившиеся
/// со скана на скан. Позиция за пределом [previous] считается изменённой (более длинный uid). Пустое
/// множество, когда [previous] `nil`/пуст (нет базы для диффа, напр. первый чип сессии) — хост тогда
/// рендерит uid обычным текстом, а не полностью приглушённым. Сравнение по сырому индексу nibble.
/// Порт `changedNibbles` (:86).
func changedNibbles(uid: String, previous: String?) -> Set<Int> {
    guard let previous, !previous.isEmpty else { return [] }
    let prev = Array(previous)
    var out: Set<Int> = []
    for (i, ch) in uid.enumerated() where i >= prev.count || ch != prev[i] {
        out.insert(i)
    }
    return out
}

// MARK: - Проверка браслета участника

/// Итог верификации одного чипа против пула `member_tags` текущей гонки.
///
/// - `ok` — UID есть в пуле; [ok.number] — номер участника.
/// - `kpChip` — UID не в пуле, но прочитан `K24`-код: это чип КП, не браслет (тапнули не тот тип).
/// - `unknown` — UID не в пуле и кода нет: чужая гонка, чистый чип или устаревший пул.
enum MemberChipCheckResult: Equatable {
    /// Браслет принадлежит участнику [number] этой гонки.
    case ok(uid: String, number: Int)
    /// Не в пуле, но прочитан КП-код — чип КП, не браслет.
    case kpChip(uid: String)
    /// Не в пуле и без КП-кода — чужой браслет, чистый чип или устаревший пул.
    case unknown(uid: String)

    /// Нормализованный UID (uppercase hex) отсканированного чипа — присутствует в каждом варианте.
    var uid: String {
        switch self {
        case let .ok(uid, _): return uid
        case let .kpChip(uid): return uid
        case let .unknown(uid): return uid
        }
    }
}

/// Решает итог верификации браслета по уже-разрешённым хостом значениям. Чисто — без I/O, без Flow.
///
/// - Parameters:
///   - uid: нормализованный UID отсканированного чипа.
///   - memberNumber: номер участника из `pool.first { $0.nfcUid == uid }?.number` — `nil`, когда UID
///     не в пуле; пул авторитетен, поэтому побеждает даже при наличии КП-кода.
///   - hasKpCode: вернул ли `readChipCode` код; консультируется только на ветке «не в пуле».
///
/// Порядок веток 1:1 с Kotlin (это спецификация): `memberNumber != nil` → [ok]; `hasKpCode` →
/// [kpChip]; иначе → [unknown].
func classifyMemberChipCheck(
    uid: String,
    memberNumber: Int?,
    hasKpCode: Bool
) -> MemberChipCheckResult {
    if let number = memberNumber {
        return .ok(uid: uid, number: number)
    }
    if hasKpCode {
        return .kpChip(uid: uid)
    }
    return .unknown(uid: uid)
}
