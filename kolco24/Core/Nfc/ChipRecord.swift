//
//  ChipRecord.swift
//  kolco24
//
//  Чистая часть формата чипа `K24` (Mifare Ultralight / NTAG). Порт 1:1 чистых
//  функций из `data/nfc/MifareUltralightWriter.kt` — сборка/разбор сырой записи,
//  hex-кодек кода, распознавание модели по GET_VERSION, плюс командная логика
//  записи/чтения поверх абстрактного транспорта `NfcTransport` (header-last
//  commit, read-back verify). `android.nfc`-обвязка (`writeChipCode`/
//  `readChipCode`/`readChipVersion`, GET_VERSION-транзакция) не портируется —
//  CoreNFC-адаптер будет в этапе 5.
//
//  Типизированный разбор: один формат `K24` несёт два типа — КП (`0x1`) и браслет
//  участника (`0x2`). ``parseChipRecord(pages:type:)`` принимает ожидаемый тип; сырые
//  страницы отдаёт ``readRecordPages(_:)``, так что сканер разбирает их дважды без
//  лишнего transceive. ``writeRecord`` сверяет read-back по типу из заголовка записи.
//
//  Порт-ловушка знаковых байтов закрыта `HexBytes` + работой на `UInt8`/`Data`.
//

import Foundation

// ---------------------------------------------------------------------------
// Сырой on-chip формат (header-first): страница 4 = 'K' '2' '4' <packed>,
// страницы 5–8 = 16-байтовый код. `packed = (version << 4) | type`; старший
// ниббл = версия, младший = тип.
// ---------------------------------------------------------------------------

/// Байт на страницу Mifare Ultralight.
private let PAGE_SIZE = 4

/// Код = один UUID = 16 байт = 4 страницы (4..7), есть на любом варианте Ultralight.
let CHIP_CODE_BYTES = PAGE_SIZE * 4

/// 24-битный магик 'K' '2' '4' (бренд Kolco24) — сентинел «это наш чип» в байтах 0..2 страницы 4.
private let MAGIC: [UInt8] = [0x4B, 0x32, 0x34]

/// Младший ниббл типа: КП (checkpoint). Единственный тип, который читают ридеры КП
/// (``parseChipRecord(pages:)``, ``readRecord(_:)``).
let CHIP_TYPE_KP = 0x1

/// Младший ниббл типа: браслет участника — серверный секретный код, записывается из
/// админки («Записать браслет участника»); читается через ``parseChipRecord(pages:type:)``.
let CHIP_TYPE_PARTICIPANT = 0x2

/// Старший ниббл версии формата.
let CHIP_FORMAT_VERSION = 0x1

/// Страница с 4-байтовым заголовком (магик + packed-байт).
let HEADER_PAGE = 4

/// Первая страница 16-байтового кода (страницы 5..8).
let CODE_PAGE_START = 5

/// Заголовок (4 байта) + код (16 байт) = 20 байт = 5 страниц (4..8).
let CHIP_RECORD_BYTES = PAGE_SIZE + CHIP_CODE_BYTES

/// Ошибки сборки записи (аналог Kotlin `IllegalArgumentException` из `require`).
enum ChipRecordError: Error, Equatable {
    case invalidCodeSize
    case typeOutOfRange
    /// hex нечётной длины или с не-hex символом (аналог Kotlin `require`/`digitToInt(16)`
    /// → `IllegalArgumentException`, который провижининг ловит под «Неверный код от сервера»).
    case invalidHex
}

/// Собирает сырую запись чипа: 3-байтовый ``MAGIC`` + packed (`version<<4 | type`)
/// байт + [code] (16 байт), всего 20 байт. Чистая — без Android. `type` — Int
/// (ниббл, 0..15); [code] должен быть 16 байт.
func buildChipRecord(type: Int, code: Data) throws -> Data {
    guard code.count == CHIP_CODE_BYTES else { throw ChipRecordError.invalidCodeSize }
    guard (0...15).contains(type) else { throw ChipRecordError.typeOutOfRange }
    let packed = UInt8(((CHIP_FORMAT_VERSION << 4) | type) & 0xFF)
    var out = Data(MAGIC)
    out.append(packed)
    out.append(code)
    return out
}

/// Разбирает сырую запись, прочитанную со страниц 4… Возвращает 16-байтовый код
/// либо `nil`, если [pages] короче нужного, магик не совпал, ниббл версии не
/// ``CHIP_FORMAT_VERSION`` (guard от несовместимости вперёд) или ниббл типа не
/// равен [type]. Хвостовой паддинг допускается. Чистая.
func parseChipRecord(pages: Data, type expectedType: Int) -> Data? {
    guard chipRecordType(pages) == expectedType else { return nil }
    let bytes = [UInt8](pages)
    return Data(bytes[PAGE_SIZE..<(PAGE_SIZE + CHIP_CODE_BYTES)])
}

/// Ниббл типа валидной K24-записи в [bytes] (длина ≥ ``CHIP_RECORD_BYTES``, магик, версия
/// ``CHIP_FORMAT_VERSION``), иначе `nil`. Общая проверка заголовка для ``parseChipRecord(pages:type:)``,
/// ``writeGuardDecision(currentPages:record:)`` и ``writeRecord``. Чистая.
private func chipRecordType(_ data: Data) -> Int? {
    if data.count < CHIP_RECORD_BYTES { return nil }
    let bytes = [UInt8](data)
    for i in MAGIC.indices where bytes[i] != MAGIC[i] {
        return nil
    }
    let packed = Int(bytes[MAGIC.count])
    if (packed >> 4) & 0x0F != CHIP_FORMAT_VERSION { return nil }
    return packed & 0x0F
}

/// Ридер КП: ``parseChipRecord(pages:type:)`` с ``CHIP_TYPE_KP`` — запись браслета
/// участника (тип `0x2`) отклоняется (`nil`), поведение прежнее.
func parseChipRecord(pages: Data) -> Data? {
    parseChipRecord(pages: pages, type: CHIP_TYPE_KP)
}

/// Разбор одного чтения сырых страниц (``readRecordPages(_:)``) в оба типа записи: `code` — K24-код
/// **КП** (``CHIP_TYPE_KP``), `memberCode` — код браслета участника (``CHIP_TYPE_PARTICIPANT``).
/// Типы взаимоисключающие (один ниббл типа), поэтому не более одного из двух не-`nil`; `nil`-страницы
/// (ошибка чтения) / пустой / чужой чип → оба `nil`. Лишнего transceive нет. Чистая.
func decodeTagPages(_ pages: Data?) -> (code: Data?, memberCode: Data?) {
    guard let pages else { return (nil, nil) }
    return (parseChipRecord(pages: pages, type: CHIP_TYPE_KP),
            parseChipRecord(pages: pages, type: CHIP_TYPE_PARTICIPANT))
}

/// Uppercase hex от [code] (без разделителей) — для отображения/записи.
func chipCodeHex(_ code: Data) -> String {
    HexBytes.encode(code, uppercase: true)
}

/// Обратная к ``chipCodeHex``; восстанавливает байты из сохраняемого hex-состояния.
/// Бросает ``ChipRecordError/invalidHex`` на нечётной длине или не-hex символе — как
/// Kotlin `require(hex.length % 2 == 0)` + `digitToInt(16)` бросают `IllegalArgumentException`
/// (провижининг ловит и показывает «Неверный код от сервера»), а не роняет процесс через
/// precondition в ``HexBytes/decode(_:)``. Валидный вход декодируется без изменений.
func chipCodeFromHex(_ hex: String) throws -> Data {
    guard hex.count % 2 == 0 else { throw ChipRecordError.invalidHex }
    guard hex.allSatisfy({ $0.hexDigitValue != nil }) else { throw ChipRecordError.invalidHex }
    return Data(HexBytes.decode(hex))
}

/// Сопоставляет 8-байтовый ответ GET_VERSION с человекочитаемой моделью чипа. Тип
/// продукта — байт 2 (`0x04` = NTAG, `0x03` = MIFARE Ultralight), размер хранилища
/// — байт 6 (`0x0F` = NTAG213, `0x11` = NTAG215, `0x13` = NTAG216). Короткий/пустой
/// ответ → "неизвестно". Чистая — никогда не бросает.
func chipModelFromVersion(_ resp: Data) -> String {
    if resp.count < 8 { return "неизвестно" }
    let bytes = [UInt8](resp)
    let productType = Int(bytes[2])
    let storageSize = Int(bytes[6])
    switch productType {
    case 0x04:
        switch storageSize {
        case 0x0F: return "NTAG213"
        case 0x11: return "NTAG215"
        case 0x13: return "NTAG216"
        default: return "NTAG (неизвестно)"
        }
    case 0x03:
        return "MIFARE Ultralight"
    default:
        return "неизвестно"
    }
}

// ---------------------------------------------------------------------------
// Командная логика записи/чтения поверх абстрактного транспорта.
// ---------------------------------------------------------------------------

/// Итог ``writeRecord``. Никогда не бросается — сообщается значением.
enum ChipWriteResult: Equatable {
    /// Все страницы записаны и подтверждены (ACK).
    case success

    /// Метка не отдаёт NfcA-tech (не ISO 14443-3A) — ничего не записано.
    case unsupported

    /// I/O-ошибка или NAK в середине записи (метку убрали, защита, чужой чип и т.п.).
    case failed(message: String)

    /// Запись НЕ начиналась: pre-write чтение текущих страниц не удалось
    /// (``ChipWriteGuard/readFailed``) — pending-write остаётся, хост просит приложить снова.
    case readFailed

    /// Запись НЕ начиналась: на чипе уже K24-запись ДРУГОГО типа (КП вместо браслета или наоборот) —
    /// ``writeGuardDecision(currentPages:record:)``. Повтор бессмыслен: хост бросает текущий чип.
    case wrongType(reason: String)
}

/// Решение pre-write guard'а (сканер вызывает на `readQueue` перед ``writeRecord`` по тому же
/// соединению). Guard на тапе 1 (`TagReading.code`/`memberCode`) обходится сбойным чтением тапа 1,
/// а ``writeRecord`` первым делом зануляет заголовок — поэтому тип проверяется и здесь.
enum ChipWriteGuard: Equatable {
    /// Писать можно: пустой/чужой чип или K24-запись того же типа (перезапись).
    case allow
    /// Не удалось прочитать текущие страницы — не пишем вслепую, pending-write остаётся (приложить снова).
    case readFailed
    /// На чипе K24-запись другого типа — не пишем (``ChipWriteResult/wrongType(reason:)``).
    case wrongType(reason: String)
}

/// Чистое решение guard'а: [currentPages] — результат ``readRecordPages(_:)`` (`nil` = ошибка чтения),
/// [record] — вооружённая 20-байтовая запись (как в ``writeRecord``). Валидная K24-запись (магик +
/// версия) с ниббл-типом, отличным от типа [record], → `wrongType` (``wrongChipTypeMessage(type:)``);
/// `nil`-страницы → `readFailed`; иначе `allow`.
func writeGuardDecision(currentPages: Data?, record: Data) -> ChipWriteGuard {
    precondition(record.count == CHIP_RECORD_BYTES, "record must be \(CHIP_RECORD_BYTES) bytes")
    guard let currentPages else { return .readFailed }
    let pendingType = [UInt8](record)[MAGIC.count] & 0x0F
    if let onChip = chipRecordType(currentPages), onChip != Int(pendingType) {
        return .wrongType(reason: wrongChipTypeMessage(type: onChip))
    }
    return .allow
}

/// Минимальный шов над открытым NfcA-соединением: отправить один сырой кадр, получить
/// ответ (или бросить). Позволяет JVM-тестировать логику последовательности команд в
/// ``writeRecord``/``readRecord`` фейком — реальный адаптер это `{ frame in nfcA.transceive(frame) }`.
/// (Kotlin `fun interface NfcTransport`.)
protocol NfcTransport {
    func transceive(_ frame: Data) throws -> Data
}

/// Ultralight / NTAG WRITE opcode — пишет одну 4-байтовую страницу: `[0xA2, page, b0, b1, b2, b3]`.
private let CMD_WRITE: UInt8 = 0xA2

/// 4-битный ACK от метки на успешный WRITE (NfcA отдаёт его одним байтом).
private let ACK: UInt8 = 0x0A

/// NTAG21x / Ultralight EV1 FAST_READ — `[0x3A, start, end]` вернёт страницы start..end одним кадром.
private let CMD_FAST_READ: UInt8 = 0x3A

/// NTAG/Ultralight READ — возвращает 16 байт (4 страницы) с указанной страницы, с заворотом за конец.
private let CMD_READ: UInt8 = 0x30

/// Один READ-ответ: 4 страницы.
private let READ_BLOCK = PAGE_SIZE * 4

/// WRITE одной страницы из `src[from ..< from+4]`; возвращает `.failed` на NAK, иначе `nil`.
private func writePage(_ t: NfcTransport, page: Int, src: Data, from: Int) throws -> ChipWriteResult? {
    let srcBytes = [UInt8](src)
    let frame = Data([
        CMD_WRITE,
        UInt8(page & 0xFF),
        srcBytes[from], srcBytes[from + 1], srcBytes[from + 2], srcBytes[from + 3],
    ])
    let response = [UInt8](try t.transceive(frame))
    if response.isEmpty || response[0] != ACK {
        return .failed(message: "Метка отклонила запись страницы \(page)")
    }
    return nil
}

/// Пишет 20-байтовую [record] (заголовок стр. 4 + код стр. 5..8) через [t] в порядке
/// **header-last**, чтобы заголовок был commit-маркером (прерванный тап не оставит валидный
/// заголовок над недописанным кодом):
/// 1. инвалидировать стр. 4 нулевым заголовком (убить прежний магик до перезаписи кода),
/// 2. записать код (стр. 5..8 = байты записи 4..19),
/// 3. записать валидный заголовок последним (стр. 4 = байты записи 0..3).
/// Затем читает обратно через **тот же** транспорт и возвращает `.failed`, если код,
/// разобранный с типом из заголовка [record] (КП или браслет), не равен `record[4..19]`.
/// Никогда не бросает.
func writeRecord(_ t: NfcTransport, record: Data) -> ChipWriteResult {
    precondition(record.count == CHIP_RECORD_BYTES, "record must be \(CHIP_RECORD_BYTES) bytes")
    do {
        // 1. инвалидировать стр. 4 (нули) до касания кода.
        if let fail = try writePage(t, page: HEADER_PAGE, src: Data(count: PAGE_SIZE), from: 0) {
            return fail
        }
        // 2. код стр. 5..8 (байты записи 4..19).
        for i in 0..<(CHIP_CODE_BYTES / PAGE_SIZE) {
            let page = CODE_PAGE_START + i
            let from = PAGE_SIZE + i * PAGE_SIZE
            if let fail = try writePage(t, page: page, src: record, from: from) {
                return fail
            }
        }
        // 3. валидный заголовок последним (commit-маркер).
        if let fail = try writePage(t, page: HEADER_PAGE, src: record, from: 0) {
            return fail
        }
        // Прочитать обратно по тому же открытому соединению и сверить код.
        // Через `[UInt8]`: `Data` может иметь ненулевой `startIndex`.
        let recordBytes = [UInt8](record)
        let expected = Data(recordBytes[PAGE_SIZE..<CHIP_RECORD_BYTES])
        let readBack = chipRecordType(record).flatMap { recordType in
            readRecordPages(t).flatMap { parseChipRecord(pages: $0, type: recordType) }
        }
        if readBack == nil || readBack != expected {
            return .failed(message: "Чтение после записи не совпало")
        }
        return .success
    } catch {
        // Аналог Kotlin `Failed(e.message ?: "Ошибка записи")`: пробрасываем детали брошенной
        // транспортом ошибки (реальный CoreNFC-транспорт этапа 5 бросает `NSError`, чей
        // `localizedDescription` несёт осмысленное сообщение), с тем же русским фолбэком.
        let detail = error.localizedDescription
        return .failed(message: detail.isEmpty ? "Ошибка записи" : detail)
    }
}

/// Читает сырые 20 байт записи (стр. 4..8) через [t] без разбора. Пробует **FAST_READ**
/// (`0x3A 04 08`) одним transceive; трактует брошенную ошибку **или** ответ короче
/// ``CHIP_RECORD_BYTES`` (метка может ответить на неподдержанную команду 1-байтовым NAK, не
/// бросая) как неудачу и падает на два обычных **READ** — стр. 4 (байты 0..15) + стр. 8
/// (первые 4 байта = байты записи 16..19). Каждый READ должен вернуть минимум ``READ_BLOCK``
/// байт; короткий/NAK-ответ или ошибка на любом READ → `nil`. Никогда не бросает.
func readRecordPages(_ t: NfcTransport) -> Data? {
    let fast: Data?
    do {
        fast = try t.transceive(Data([CMD_FAST_READ, UInt8(HEADER_PAGE), UInt8(HEADER_PAGE + 4)]))
    } catch {
        fast = nil
    }
    if let fast, fast.count >= CHIP_RECORD_BYTES {
        return Data([UInt8](fast)[0..<CHIP_RECORD_BYTES])
    }
    do {
        let head = try t.transceive(Data([CMD_READ, UInt8(HEADER_PAGE)]))
        if head.count < READ_BLOCK { return nil }
        let tail = try t.transceive(Data([CMD_READ, UInt8(HEADER_PAGE + 4)]))
        if tail.count < READ_BLOCK { return nil }
        let headBytes = [UInt8](head)
        let tailBytes = [UInt8](tail)
        var combined = Array(headBytes[0..<READ_BLOCK])
        combined.append(contentsOf: tailBytes[0..<(CHIP_RECORD_BYTES - READ_BLOCK)])
        return Data(combined)
    } catch {
        return nil
    }
}

/// Ридер КП: ``readRecordPages(_:)`` + ``parseChipRecord(pages:)``. Возвращает код КП либо
/// `nil` (нет записи, чужой/браслетный тип, ошибка чтения). Никогда не бросает.
func readRecord(_ t: NfcTransport) -> Data? {
    readRecordPages(t).flatMap { parseChipRecord(pages: $0) }
}
