//
//  MarkMetrics.swift
//  kolco24
//
//  Чистые Android-free хелперы очков из локальных взятий КП. Kotlin-источник:
//  чистые top-level функции `data/MarkRepository.kt` (`takenPoints`,
//  `takenPointCount` — обе перегрузки, `totalScore` — обе перегрузки). DAO-часть
//  `MarkRepository` уже зеркалирована `MarkStore`-тестами этапа 2 — здесь только
//  чистые деривации.
//
//  «Взято» не пишется обратно на строку КП: оно team-scoped (общий на гонку КП
//  иначе протёк бы прогрессом одной команды на другую), поэтому легенда выводит
//  его из complete-взятий этой команды через [takenPoints].
//

import Foundation

/// Множество id КП (пунктов), зачтённых этими взятиями — «взято» команды,
/// выведенное из её собственных complete-взятий. Легенда использует это вместо
/// персистентного флага на КП, чтобы смена команды в гонке показывала прогресс
/// именно этой команды. Порт `takenPoints`.
func takenPoints(_ marks: [Mark]) -> Set<Int> {
    var result = Set<Int>()
    for mark in marks where mark.complete {
        result.insert(mark.checkpointId)
    }
    return result
}

/// Число различных зачтённых (complete) КП. Порт `takenPointCount(marks)`.
func takenPointCount(_ marks: [Mark]) -> Int {
    distinctCompleteCheckpointIds(marks).count
}

/// Число различных зачтённых (complete) КП c **живым** резолвером цены, считая
/// только scoring-КП (`cost > 0`) — технические КП (cost 0: тест-пункт, зона
/// передачи) не идут в «ВЗЯТО». [costOf] зеркалит резолвер перегрузки
/// [totalScore]. Порт `takenPointCount(marks, costOf)`.
func takenPointCount(_ marks: [Mark], costOf: (Mark) -> Int) -> Int {
    distinctCompleteMarks(marks).filter { costOf($0) > 0 }.count
}

/// Сумма cost по различным зачтённым КП — повторное взятие того же пункта не
/// удваивает счёт. Использует снимок cost, вбитый в строку взятия на момент
/// взятия. Порт `totalScore(marks)`.
func totalScore(_ marks: [Mark]) -> Int {
    totalScore(marks) { $0.cost }
}

/// Сумма cost по различным зачтённым КП с **живым** резолвером цены вместо снимка
/// на строке взятия. [costOf] возвращает текущую цену КП (живой
/// `Checkpoint.cost`) с фолбэком на снимок взятия, когда пункт отсутствует в
/// легенде — держит «Отметки» СУММА в шаге с «Легенда» после серверной правки
/// цены. Порт `totalScore(marks, costOf)`.
func totalScore(_ marks: [Mark], costOf: (Mark) -> Int) -> Int {
    distinctCompleteMarks(marks).reduce(0) { $0 + costOf($1) }
}

/// Complete-взятия, различные по `checkpointId`, в порядке первого появления.
private func distinctCompleteMarks(_ marks: [Mark]) -> [Mark] {
    var seen = Set<Int>()
    var result: [Mark] = []
    for mark in marks where mark.complete {
        if seen.insert(mark.checkpointId).inserted {
            result.append(mark)
        }
    }
    return result
}

/// Множество различных id complete-взятий.
private func distinctCompleteCheckpointIds(_ marks: [Mark]) -> Set<Int> {
    var seen = Set<Int>()
    for mark in marks where mark.complete {
        seen.insert(mark.checkpointId)
    }
    return seen
}
