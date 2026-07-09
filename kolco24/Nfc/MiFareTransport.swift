//
//  MiFareTransport.swift
//  kolco24
//
//  CoreNFC-адаптер чистого шва `NfcTransport` (Core/Nfc/ChipRecord). Порт `readChipCode`-адаптера
//  из Android (`data/nfc/MifareUltralightWriter.kt`), где чтение шло `nfcA.transceive(frame)`; на
//  iOS сырой кадр гоняется через `NFCMiFareTag.sendMiFareCommand`. Чистая последовательность команд
//  (FAST_READ 0x3A → фоллбек 2×READ 0x30, разбор K24) остаётся в `Core/Nfc/readRecord` — здесь только
//  мост «колбэчный CoreNFC → синхронный `transceive`».
//
//  ⚠️ ДЕДЛОК-ЛОВУШКА. `readRecord`/`writeRecord` синхронно циклят `transceive`, поэтому каждый вызов
//  блокирует поток `DispatchSemaphore`, пока CoreNFC не доставит колбэк `sendMiFareCommand`. Этот
//  блокирующий `wait()` ОБЯЗАН выполняться НЕ на очереди колбэков CoreNFC (делегатной очереди сессии),
//  иначе `wait` заблокирует ту самую серийную очередь, на которой должен прийти колбэк, — и сессия
//  зависнет навсегда. Гарантию даёт ВЫЗЫВАЮЩИЙ: `NfcChipScanner` гоняет `readRecord` на своей выделенной
//  фоновой `readQueue`, отдельной от делегатной очереди сессии. Сам транспорт очередь не выбирает.
//

import CoreNFC
import Foundation

/// `NfcTransport` поверх открытого `NFCMiFareTag`: один сырой кадр → один ответ (или брошенная ошибка).
/// Соответствует контракту `readRecord`, который трактует брошенное как «команда не поддержана» и
/// падает на фоллбек.
struct MiFareTransport: NfcTransport {
    let tag: NFCMiFareTag

    /// Синхронно отправляет кадр и блокирующе ждёт ответ. См. дедлок-ловушку в шапке файла — вызывать
    /// только с фоновой очереди, не с делегатной очереди NFC-сессии.
    func transceive(_ frame: Data) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        var response: Data?
        var failure: Error?
        tag.sendMiFareCommand(commandPacket: frame) { data, error in
            if let error {
                failure = error
            } else {
                response = data
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let failure { throw failure }
        return response ?? Data()
    }
}
