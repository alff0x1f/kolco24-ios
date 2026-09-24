//
//  UnlockOutcome.swift
//  kolco24
//
//  Persistence-aware итог `LegendRepository.unlock` — трансляция репозиторием
//  крипто-итога движка (`UnlockResult` из `LegendCrypto`). Зеркало sealed-иерархии
//  `UnlockOutcome` (`data/LegendRepository.kt:196–209`).
//
//  Не путать с `RevealedCheckpoint` из `LegendCrypto` — это другой тип
//  (крипто-уровень). `classifyTag` (этап 6) матчит все 4 кейса, включая
//  `unknown → badKp`.
//

/// Итог раскрытия тега относительно локальной БД. Кейс [unknown] не имеет
/// аналога в движке — он означает, что просканированный `bid` не совпал ни с
/// одним тегом.
enum UnlockOutcome: Equatable {
    /// Раскрытые [checkpointIds] расшифрованы и сохранены; тег принадлежит
    /// [checkpointId]. [checkMethod] — сырой `check_method` тега (`offline`/`cloud`/`local`),
    /// снапшотится во взятие КП.
    case revealed(checkpointId: Int, checkpointIds: [Int], checkMethod: String)

    /// Open-CP тег: только идентифицирует свой [checkpointId], расшифровывать
    /// нечего. [checkMethod] — как у [revealed].
    case identityOnly(checkpointId: Int, checkMethod: String)

    /// Ни один тег не совпал со скан-`bid` (неизвестный тег для этого набора гонки).
    case unknown

    /// Крипто- или парс-ошибка (неверный ключ, подделка, битый bundle).
    case failed(reason: String)
}
