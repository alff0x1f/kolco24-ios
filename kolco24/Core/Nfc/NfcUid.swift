//
//  NfcUid.swift
//  kolco24
//
//  Kotlin-источник: `data/NfcUid.kt`.
//

import Foundation

/// Нормализует сырой id NFC-метки в серверный формат пула: каждый байт — двухсимвольная
/// пара hex в верхнем регистре с ведущим нулём (`0x04` → `"04"`), склеенные подряд. Пул
/// `member_tags` приходит уже нормализованным (trim + UPPERCASE), поэтому прочитанные UID
/// нормализуются так же перед сравнением. Пустой массив → пустая строка.
func normalizeNfcUid(_ raw: Data) -> String {
    HexBytes.encode(raw, uppercase: true)
}
