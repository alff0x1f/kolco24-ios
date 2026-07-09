//
//  LegendDisplay.swift
//  kolco24
//
//  Чистая Android-free derived-логика вкладки «Легенда». Kotlin-источники:
//  `ui/legend/CheckpointColor.kt` (`parseCheckpointColor`) + чистые функции
//  `ui/legend/LegendScreen.kt` (`isScoring`, `groupCheckpointsByColor`, ширины
//  скелетон-строки locked-КП). Никакого UIKit/SwiftUI — всё юнит-покрыто.
//
//  Сервер шлёт `color` именованным семантическим токеном (`""`, `"red"`,
//  `"blue"`, `"green"`, `"yellow"`, `"orange"`, `"purple"`), не hex/RGB. `""` и
//  любой неизвестный/будущий токен парсятся в `nil` (forward-compatible — не
//  падаем на добавленном позже серверном токене). Маппинг токен → цвет пикселя
//  живёт во вьюхе (дизайн-токены), никогда здесь.
//

import Foundation

/// Семантический цвет дисциплины КП. `nil` (не enum-кейс) — для `""`/неизвестного
/// токена. Зеркало Kotlin `enum class CheckpointColor`.
enum CheckpointColor {
    case red
    case blue
    case green
    case yellow
    case orange
    case purple
}

/// Парсит серверный цветовой токен в [CheckpointColor]; `nil` для `""` или любого
/// нераспознанного токена. Порт `parseCheckpointColor` (`CheckpointColor.kt`).
func parseCheckpointColor(_ token: String) -> CheckpointColor? {
    switch token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "red": return .red
    case "blue": return .blue
    case "green": return .green
    case "yellow": return .yellow
    case "orange": return .orange
    case "purple": return .purple
    default: return nil
    }
}

extension Checkpoint {
    /// КП идёт в зачёт scoring-счётчика: открытый должен иметь `cost > 0`
    /// (технические КП — `cost == 0`); у locked-КП цена скрыта клиентом, так что
    /// он считается scoring — серверный `scoring_count` его уже включает.
    /// Порт `CheckpointEntity.isScoring()` (`LegendScreen.kt`).
    var isScoring: Bool {
        locked || (cost ?? 0) > 0
    }
}

/// Группирует КП в карточки по подряд идущему цвету, сохраняя входной порядок
/// (номер, id). `""`/неизвестные токены сворачиваются в одну нейтральную группу
/// (`nil == nil`); цвет, вернувшийся отдельным раном, остаётся отдельной картой
/// (КП разложены в порядке маршрута, не отсортированы по цвету). Порт
/// `groupCheckpointsByColor` (`LegendScreen.kt`).
func groupCheckpointsByColor(_ checkpoints: [Checkpoint]) -> [[Checkpoint]] {
    var groups: [[Checkpoint]] = []
    for cp in checkpoints {
        let color = parseCheckpointColor(cp.color)
        if let current = groups.last,
           let first = current.first,
           parseCheckpointColor(first.color) == color {
            groups[groups.count - 1].append(cp)
        } else {
            groups.append([cp])
        }
    }
    return groups
}

/// Ширины плейсхолдер-баров скелетон-строки locked-КП, детерминированы от `id`
/// (стабильны между перерисовками, но варьируются от строки к строке, чтобы
/// маскированный список читался как реальный текст). Порт логики
/// `LockedCheckpointRow` (`LegendScreen.kt`, `Math.floorMod`).
struct LockedSkeletonBars: Equatable {
    let firstBarFraction: Float
    let hasSecondBar: Bool
    let secondBarFraction: Float
}

/// Скелетон-бары locked-строки для КП с данным [checkpointId]. Использует
/// floor-mod (как `Math.floorMod` — результат всегда неотрицателен), поэтому
/// совпадает с Kotlin даже для гипотетического отрицательного id.
func lockedSkeletonBars(checkpointId: Int) -> LockedSkeletonBars {
    LockedSkeletonBars(
        firstBarFraction: 0.50 + Float(floorMod(checkpointId * 17, 44)) / 100.0,
        hasSecondBar: floorMod(checkpointId * 13, 3) == 0,
        secondBarFraction: 0.28 + Float(floorMod(checkpointId * 29, 26)) / 100.0
    )
}

/// Floor-модуль: результат имеет знак делителя (для положительного `mod` всегда
/// `0..<mod`), в отличие от Swift `%`. Зеркало `Math.floorMod`.
private func floorMod(_ value: Int, _ mod: Int) -> Int {
    let r = value % mod
    return (r != 0 && (r < 0) != (mod < 0)) ? r + mod : r
}
