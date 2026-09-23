//
//  ProvisioningLogic.swift
//  kolco24
//
//  Чистая логика провижининга (привязка чипа к КП с записью кода) — этап 10. Порт
//  `ui/admin/ProvisioningModel.kt` (`ProvisionState` :21, `provisionErrorMessage` :77,
//  `chipTokenLabel` :92). Хост (`ProvisioningModel`, App-слой, Task 12) владеет списком КП,
//  NFC-хуком и сайд-эффектами bind/write; здесь — только состояние текущего чипа и
//  пользовательские строки.
//
//  Deviation от Android:
//  - `ProvisionState` — **двухтаповый** флоу iOS: `waitingForWrite(uid:code:)` заменяет Kotlin-евый
//    `Writing` (тап 1 — bind, сервер выдал `code`; тап 2 — сверка того же uid + запись). Надёжно при
//    медленной сети на старте; header-last гарантирует безопасность повтора тапа 2.
//  - `railTicks`/`RailTick` **не портируются** — `HorizontalPager` + rail-тики заменены на
//    список/степпер КП (идиоматичный iOS-паттерн).
//
//  `Core/Admin/` — Foundation-only (grep-инвариант этапа 9/10): без сети/GRDB/UI. `PostResult` —
//  Foundation-only enum того же модуля (импорт не нужен), так что инвариант не нарушается.
//

import Foundation

// MARK: - Состояние текущего чипа

/// Состояние чипа, провижинимого против выбранного КП. Пустая зона скана и свежий КП — в
/// [waitingForChip]; тапнутый чип идёт [binding] → [waitingForWrite] → [success] (или [failed] на
/// любой ошибке). Хост штампует новое состояние на каждый тап и сбрасывает в [waitingForChip] при
/// переходе на другой КП.
enum ProvisionState: Equatable {
    /// Чип не в работе — зона скана пульсирует «Приложите чип к телефону».
    case waitingForChip
    /// Чип с [uid] прочитан и биндится к КП на сервере (`POST .../tags/`).
    case binding(uid: String)
    /// Bind вернул `code`; ждём **повторного** прикладывания того же чипа [uid], чтобы записать [code].
    case waitingForWrite(uid: String, code: String)
    /// Чип привязан и записан: он теперь несёт КП с человеко-читаемым [number].
    case success(number: Int)
    /// Bind или запись провалились; [reason] — пользовательская RU-строка для зоны скана.
    case failed(reason: String)
}

// MARK: - Пользовательские строки

/// Маппит **не-success** [result] от `bindTag` в пользовательскую RU-строку для зоны скана. Хост
/// обрабатывает `.success` до вызова; неожиданный `.success` падает в `else` и возвращает
/// «Ошибка сервера» как безопасный фолбэк. Строки — байт-в-байт из Kotlin `provisionErrorMessage`.
///
/// - `409` (`.conflict`) → «уже привязан к другому КП». Тело `409` не несёт номер КП, поэтому
///   строка **обобщённая** — назвать другой КП нельзя.
/// - `404` (`.error(404)`) → «КП не найдено» (КП не биндится).
/// - `403` (`.forbidden`) → покрывает **и** не-админа, **и** ошибку подписи/часов (спека возвращает
///   `403` в обоих случаях), отсюда объединённая строка.
func provisionErrorMessage<T>(_ result: PostResult<T>) -> String {
    switch result {
    case .conflict: return "Этот тег уже привязан к другому КП"
    case .forbidden: return "Нет прав администратора этой гонки или ошибка подписи/часов"
    case .unauthorized: return "Сессия истекла, войдите снова"
    case .badRequest: return "Неверный запрос"
    case .rateLimited: return "Слишком часто, подождите немного"
    case .offline: return "Нет сети, попробуйте снова"
    case .error(let code): return code == 404 ? "КП не найдено" : "Ошибка сервера"
    case .success: return "Ошибка сервера"
    }
}

/// Общие RU-строки обоих экранов записи (чипы КП и браслеты участников) + pre-write guard'а
/// сканера (``writeGuardDecision(currentPages:record:)``) — один источник для Core, моделей и вьюх.
enum ProvisionMessage {
    /// Тап 1 не прочитался (`TagReading.readFailed`) или не прочитался pre-write guard тапа 2.
    static let readFailedTapAgain = "Не удалось прочитать, приложите снова"
    /// Запись на тапе 2 не удалась (`failed`/`unsupported`) — pending-write сохранён.
    static let writeFailedTapAgain = "Не удалось записать, приложите снова"
    /// Подсказка тапа 2 по умолчанию, экран КП.
    static let kpWriteAgainHint = "Приложите чип ещё раз"
    /// Подсказка тапа 2 по умолчанию, экран браслетов (зона скана и системная NFC-шторка).
    static let memberWriteAgainHint = "Приложите браслет ещё раз"
    /// На экране браслетов приложен чип КП.
    static let kpChipNotBracelet = "Это чип КП, а не браслет"
    /// На экране КП приложен браслет участника.
    static let memberBracelet = "Это браслет участника"
    /// На чипе K24-запись неизвестного типа.
    static let otherChipType = "Чип другого типа"
}

/// Отказ записи из-за K24-записи типа [type], уже лежащей на чипе. Чистая.
func wrongChipTypeMessage(type: Int) -> String {
    switch type {
    case CHIP_TYPE_KP: return ProvisionMessage.kpChipNotBracelet
    case CHIP_TYPE_PARTICIPANT: return ProvisionMessage.memberBracelet
    default: return ProvisionMessage.otherChipType
    }
}

/// Короткая метка свежезаписанного чипа — последние 4 hex-символа нормализованного [uid] (уже
/// в верхнем регистре). Более короткий uid возвращается целиком. Чистая.
func chipTokenLabel(uid: String) -> String {
    uid.count <= 4 ? uid : String(uid.suffix(4))
}
