//
//  HexBytes.swift
//  kolco24
//
//  Единственное место hex-идиомы `%02x` в проекте (порт-ловушка: `%02x` на
//  отрицательном `Int8` в Swift даёт sign-extension). Всё крутится на `UInt8`/`Data`,
//  байт нормализуется через `& 0xFF`, как Kotlin `b.toInt() and 0xFF`.
//
//  Kotlin-источник: размазанная по файлам идиома `HEX[v ushr 4]` / `digitToInt(16)`
//  (`data/NfcUid.kt`, `data/nfc/MifareUltralightWriter.kt`).
//

import Foundation

enum HexBytes {

    private static let lowerDigits = Array("0123456789abcdef")
    private static let upperDigits = Array("0123456789ABCDEF")

    /// Байты → hex-строка без разделителей. `uppercase: true` — как `normalizeNfcUid`/`chipCodeHex`.
    static func encode<S: Sequence>(_ bytes: S, uppercase: Bool = false) -> String where S.Element == UInt8 {
        let digits = uppercase ? upperDigits : lowerDigits
        var out = ""
        for b in bytes {
            let v = Int(b)
            out.append(digits[v >> 4])
            out.append(digits[v & 0x0F])
        }
        return out
    }

    /// hex-строка → байты. Аналог `chipCodeFromHex`: требует чётную длину, `digitToInt(16)` по символу.
    static func decode(_ hex: String) -> [UInt8] {
        precondition(hex.count % 2 == 0, "hex must have even length")
        let chars = Array(hex)
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            let hi = digitToInt(chars[i])
            let lo = digitToInt(chars[i + 1])
            out.append(UInt8((hi << 4) | lo))
            i += 2
        }
        return out
    }

    private static func digitToInt(_ c: Character) -> Int {
        guard let v = c.hexDigitValue else {
            preconditionFailure("invalid hex digit: \(c)")
        }
        return v
    }
}
