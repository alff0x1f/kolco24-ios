//
//  MemberChipBinding.swift
//  kolco24
//
//  Доменный тип «привязка браслета к участнику». Зеркало Room-сущности
//  `MemberChipBindingEntity` (`data/db/MemberChipBindingEntity.kt`) — локальная
//  привязка физического NFC-браслета к слоту участника выбранной команды.
//  GRDB-конформанс — в `Data/Records/MemberChipBinding+GRDB.swift` (этап 2).
//
//  Слот определяется парой `(teamId, numberInTeam)`, т.к. у участника нет
//  стабильного id — только имя и `number_in_team`. Эта таблица никогда не
//  выгружается на бэкенд.
//

/// Привязка браслета к одному слоту участника. [nfcUid] — нормализованный uid,
/// прочитанный с чипа; [participantNumber] — глобальный номер участника из пула
/// `member_tags`, разрешённый в момент привязки.
struct MemberChipBinding: Equatable {
    let teamId: Int
    let numberInTeam: Int
    let nfcUid: String
    let participantNumber: Int
}
