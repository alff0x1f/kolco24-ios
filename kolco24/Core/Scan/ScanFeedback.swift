//
//  ScanFeedback.swift
//  kolco24
//
//  Порт 1:1 `ui/scan/ScanFeedback.kt` — чистый маппер скан-события оверлея в
//  аудио/тактильный исход. `neutral` намеренно не возвращается этим маппером
//  (это не-оверлейный исход прямых `neutral()`-вызовов).
//

/// Три аудио/тактильных исхода скан-тапа, проигрываемых `ScanFeedbackPlayer`.
///
/// - [success] — прочитан валидный распознанный чип (КП/участник; bind ok; check
///   ok; provision записан).
/// - [failure] — распознанный, но отклонённый тап (`badKp`/`unboundChip`,
///   not-in-pool, check unknown/inconsistent/no-code, provision/server error).
/// - [neutral] — одиночный короткий баз **без звука**; производится **только**
///   не-оверлейными путями. Никогда не результат [feedbackFor].
enum ScanFeedbackKind {
    case success
    case failure
    case neutral
}

/// Чистый маппер из скан-оверлейного [ScanEvent] в его [ScanFeedbackKind].
///
/// Исчерпывающ по четырём вариантам `ScanEvent` (без `default`):
/// [ScanEvent.kp]/[ScanEvent.member] → [ScanFeedbackKind.success],
/// [ScanEvent.unboundChip]/[ScanEvent.badKp] → [ScanFeedbackKind.failure].
/// [ScanFeedbackKind.neutral] **намеренно никогда не возвращается** здесь.
func feedbackFor(event: ScanEvent) -> ScanFeedbackKind {
    switch event {
    case .kp, .member:
        return .success
    case .unboundChip, .badKp:
        return .failure
    }
}
