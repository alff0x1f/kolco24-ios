//
//  MemberProvisioningLogic.swift
//  kolco24
//
//  Чистая логика записи кода на браслет участника (формат `K24`, тип `CHIP_TYPE_PARTICIPANT`).
//  Аналог `ProvisioningLogic` для КП: здесь — только состояние текущего браслета, парсинг номера
//  из поля ввода и пользовательские строки. Хост (`MemberProvisioningModel`, App-слой) владеет
//  пулом `member_tags`, NFC-хуком и сайд-эффектами bind/write.
//
//  Два режима в одном флоу: UID браслета есть в пуле (или записан в этой сессии) → запрос с
//  `number: null`, сервер сам знает номер; UID неизвестен (или сервер ответил `404`) → админ
//  вводит номер ([needsNumber]).
//
//  `Core/Admin/` — Foundation-only (grep-инвариант): без сети/GRDB/UI. `PostResult` —
//  Foundation-only enum того же модуля.
//

import Foundation

// MARK: - Состояние текущего браслета

/// Состояние браслета, на который пишется код участника. Тап 1 — UID → [binding] (сервер выдаёт
/// `code`) → [waitingForWrite]; тап 2 — тот же UID → запись → [success]. Неизвестный UID сначала
/// проходит через [needsNumber].
enum MemberProvisionState: Equatable {
    /// Браслет не в работе — зона скана ждёт «Приложите браслет к телефону».
    case waitingForChip
    /// UID [uid] не найден в пуле (или сервер ответил `404`) — ждём ввода номера участника.
    case needsNumber(uid: String)
    /// Идёт `POST .../member_tags/bind/` для [uid]; [number] == `nil` — номер знает сервер (UID в пуле).
    case binding(uid: String, number: Int?)
    /// Сервер выдал код для участника [number]; ждём **повторного** прикладывания браслета [uid].
    case waitingForWrite(uid: String, number: Int)
    /// Код записан и прошёл read-back: браслет теперь несёт код участника [number].
    case success(number: Int)
    /// Bind или запись провалились; [reason] — пользовательская RU-строка для зоны скана.
    case failed(reason: String)
}

// MARK: - Пользовательские строки

/// Маппит **не-success** [result] от `bindMemberTag` в RU-строку для зоны скана. Отличия от
/// `provisionErrorMessage` (КП):
/// - `409` → браслет (этот UID) уже привязан к **другому** номеру;
/// - `404` доходит сюда только на запросе **с номером** (на `number: null` хост уходит в
///   `needsNumber`) → «Не найдено на сервере».
/// Остальное (включая неожиданный `.success`) делегируется `provisionErrorMessage`.
func memberProvisionErrorMessage<T>(_ result: PostResult<T>) -> String {
    switch result {
    case .conflict: return "Браслет уже привязан к другому участнику"
    case .error(let code) where code == 404: return "Не найдено на сервере"
    default: return provisionErrorMessage(result)
    }
}

/// Строка системной NFC-шторки для [state] (шторка модальна и закрывает экран — все подсказки должны
/// дублироваться в ней). [hint] — текущая подсказка тапа 2 (`nil` → «Приложите браслет ещё раз»). Чистая.
func memberProvisionStatusLine(_ state: MemberProvisionState, hint: String?) -> String {
    switch state {
    case .waitingForChip: return "Приложите браслет участника"
    case .needsNumber: return "Введите номер участника"
    case .binding: return "Привязка на сервере…"
    case let .waitingForWrite(_, number): return "\(hint ?? ProvisionMessage.memberWriteAgainHint) (№\(number))"
    case let .success(number): return "Записано: №\(number)"
    case let .failed(reason): return "Ошибка: \(reason)"
    }
}

// MARK: - Номер участника

/// Разбирает текст поля номера. Только ASCII-цифры (пробелы по краям обрезаются), ведущие нули
/// допустимы; пусто, `0`, знак, не-число и переполнение `Int` → `nil`. Чистая.
func parseMemberNumber(_ text: String) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
    guard let n = Int(trimmed), n >= 1 else { return nil }
    return n
}
