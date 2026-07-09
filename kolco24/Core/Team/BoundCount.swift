//
//  BoundCount.swift
//  kolco24
//
//  Чистый Android-free хелпер: число участников актуального ростера с привязанным
//  чипом. Порт Kotlin `members.count { bindings.containsKey(it.numberInTeam) }` —
//  считаются только слоты текущего ростера (устаревшие записи удалённых участников
//  игнорируются). Общий для вкладок «Команда» (`TeamModel`) и «Отметки» (`MarksModel`),
//  чтобы derived-логика жила в одном тестируемом месте. Никакого UIKit/SwiftUI/GRDB.
//

import Foundation

/// Число участников [members], у которых есть привязанный чип в [bindings]
/// (ключ — `numberInTeam`). Порт `members.count { bindings.containsKey(it.numberInTeam) }`.
func boundCount(members: [TeamMemberItem], bindings: [Int: MemberChipBinding]) -> Int {
    members.reduce(0) { $0 + (bindings[$1.numberInTeam] != nil ? 1 : 0) }
}
