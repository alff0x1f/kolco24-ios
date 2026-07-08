//
//  BindDecision.swift
//  kolco24
//
//  Чистое решение флоу привязки браслета к слоту участника. Порт 1:1 чистого
//  верха `ui/team/BindChipSheet.kt` (Compose-часть — `BindChipSheet`, состояния
//  листа — не портируется). Хост вооружает NFC, на каждый прочитанный uid зовёт
//  `decideBind` и отображает исход.
//
//  Зависимости (готовы предыдущими задачами): `MemberChipBinding` (Model/).
//

/// Идентификатор одного слота участника команды (ключ привязки — см.
/// `MemberChipBinding`).
struct SlotKey: Equatable {
    let teamId: Int
    let numberInTeam: Int
}

/// Чистое решение флоу привязки: по прочитанному [uid], номеру участника
/// [poolNumber], в который он разрешается в пуле `member_tags` выбранной гонки
/// (`nil` = не в пуле), текущей привязке [existing], держащей этот uid (из
/// `findByUid`, или `nil`), и привязываемому слоту [currentSlot] — решить, что
/// должен сделать лист. Вынесено, чтобы ветвление тестировалось без Compose/NFC.
func decideBind(
    uid: String,
    poolNumber: Int?,
    existing: MemberChipBinding?,
    currentSlot: SlotKey
) -> BindOutcome {
    guard let poolNumber else { return .notInPool }
    if let existing {
        let existingSlot = SlotKey(teamId: existing.teamId, numberInTeam: existing.numberInTeam)
        if existingSlot == currentSlot {
            return .alreadyOnThisSlot(participantNumber: poolNumber)
        } else {
            return .alreadyBound(otherSlot: existingSlot, participantNumber: poolNumber)
        }
    }
    return .readyToBind(participantNumber: poolNumber)
}

/// Исход [decideBind].
enum BindOutcome: Equatable {
    /// Прочитанный uid не из пула `member_tags` гонки — отказать, ничего не сохранять.
    case notInPool

    /// Uid уже привязан к другому [otherSlot]; переназначение сдвинет его (предупредить + разрешить).
    case alreadyBound(otherSlot: SlotKey, participantNumber: Int)

    /// Uid свободен и в пуле — привязать, разрешив в [participantNumber].
    case readyToBind(participantNumber: Int)

    /// Uid уже привязан ровно к этому слоту — делать нечего; [participantNumber] для отображения.
    case alreadyOnThisSlot(participantNumber: Int)
}
