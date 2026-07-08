//
//  PhotoTarget.swift
//  kolco24
//
//  Чистый роутер фото-отметки. Порт 1:1 `data/marks/PhotoTarget.kt` целиком:
//  куда должна упасть свежая фото-сессия (прикрепиться к недавнему взятию или
//  спросить номер КП), разрешение номера КП против легенды, фильтр легенды по
//  свободному тексту для пикера номера. Никакого Android.
//
//  Зависимости (готовы предыдущими задачами): `Mark`, `Checkpoint` (Model/).
//

import Foundation

/// Окно после последнего полного взятия, в течение которого фото авто-прикрепляется к нему (3 минуты).
let PHOTO_ATTACH_WINDOW_MS: Int64 = 180_000

/// Куда должна упасть свежая фото-сессия — чистый, Android-free роутер точки входа.
///
/// [attachTo] означает, что полное взятие случилось достаточно недавно (в пределах
/// [PHOTO_ATTACH_WINDOW_MS]), так что фото трактуется как дополнительное свидетельство того же КП —
/// без запроса номера, переиспользуется существующая строка `Mark` (и её античит-координата).
/// [askNumber] означает, что недавнего взятия нет, и пользователь должен выбрать номер КП до съёмки
/// (после чего создаётся новая отдельная фото-отметка).
enum PhotoTarget: Equatable {
    /// Прикрепить фото к существующему взятию [markId] (КП [cpNumber] / [checkpointId]).
    case attachTo(markId: String, cpNumber: Int, checkpointId: Int)

    /// Недавнего взятия нет — спросить у пользователя номер КП, затем создать отдельную фото-отметку.
    case askNumber
}

/// Решить, прикрепляется ли новая фото-сессия к недавнему взятию или должна спросить номер КП.
///
/// Новейшее **полное** взятие, чьё эффективное время (`trustedTakenAt ?? takenAt`, зеркало галереи
/// отметок) в пределах [PHOTO_ATTACH_WINDOW_MS] от [nowMs], даёт [PhotoTarget.attachTo]; иначе
/// [PhotoTarget.askNumber]. Неполные взятия игнорируются (они хранятся только для серверного лога).
/// Граница окна включающая (ровно 3 минуты всё ещё прикрепляется).
func decidePhotoTarget(marks: [Mark], nowMs: Int64) -> PhotoTarget {
    let latest = marks
        .filter { $0.complete && $0.method != "photo" }
        .max { ($0.trustedTakenAt ?? $0.takenAt) < ($1.trustedTakenAt ?? $1.takenAt) }
    guard let latest else { return .askNumber }
    let takenAt = latest.trustedTakenAt ?? latest.takenAt
    if nowMs - takenAt <= PHOTO_ATTACH_WINDOW_MS {
        return .attachTo(
            markId: latest.id,
            cpNumber: latest.checkpointNumber,
            checkpointId: latest.checkpointId
        )
    } else {
        return .askNumber
    }
}

/// Разрешить номер КП, введённый пользователем, против синхронизированной [legend]. Возвращает
/// совпавший КП или `nil`, если номера нет (поведение v1 «предупреждение, если не в легенде» — без
/// сиротской отметки).
///
/// **Locked**-КП (`locked = true`, `cost = nil`) намеренно всё же разрешается: это ядро сценария
/// «метку сорвали» (код так и не был прочитан, КП остаётся нераскрытым). Фото-отметка всё равно идёт
/// в зачёт как гибрид (`complete = true`, cost = 0 пока locked); после позднего раскрытия live-cost
/// резолвер подхватит реальное значение.
func resolvePhotoCheckpoint(number: Int, legend: [Checkpoint]) -> Checkpoint? {
    legend.first { $0.number == number }
}

/// Отфильтровать [legend] для пикера номера фото по свободному тексту [query]. Пустой query возвращает
/// всю легенду (порядок ввода сохранён). Иначе КП совпадает, когда строка его номера содержит
/// обрезанный query (основной числовой путь) или его описание содержит его без учёта регистра (чтобы
/// именованный открытый КП находился по тексту); locked-КП без описания всё же совпадает по номеру.
/// Чистая и Android-free, поэтому JVM-юнит-тестируется.
func filterCheckpointsByQuery(legend: [Checkpoint], query: String) -> [Checkpoint] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
    if q.isEmpty { return legend }
    let lower = q.lowercased()
    return legend.filter { cp in
        String(cp.number).contains(q) ||
            (cp.description?.lowercased().contains(lower) ?? false)
    }
}
