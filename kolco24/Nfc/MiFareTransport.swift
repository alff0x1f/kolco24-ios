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

    /// Разделяется между всеми `transceive` одного открытого соединения (не сбрасывается на копиях
    /// структуры — `struct` со ссылочным полем). После первого таймаута кадра дальнейшие вызовы
    /// падают немедленно, не отправляя новую команду: колбэк на не пришедший кадр мог не потеряться,
    /// а лишь задержаться, и параллельная отправка второй команды тому же тегу, пока первая ещё в
    /// полёте, может испортить обмен командами CoreNFC. `readRecord`/`writeRecord` трактуют брошенное
    /// как «команда не поддержана»/ошибку и переходят к следующему шагу (фоллбек READ, ранний return) —
    /// без этого флага тот следующий шаг сам стал бы той самой параллельной командой.
    private let poisoned = TimeoutFlag()

    /// Страховочный таймаут одного кадра: обычно CoreNFC отвечает (данные или ошибка «tag connection
    /// lost») за десятки мс, но потерянный колбэк навсегда заблокировал бы `readQueue` — все последующие
    /// тапы уходили бы в очередь за зависшим чтением («чипы не сканируются» до переоткрытия оверлея).
    private static let frameTimeout: DispatchTimeInterval = .seconds(2)

    /// Не пришедший в таймаут колбэк — трактуется контрактом `readRecord` как «команда не поддержана»
    /// (фоллбек-ветка), т.е. чтение деградирует, но очередь не зависает.
    private struct FrameTimeout: Error {}

    /// Синхронно отправляет кадр и блокирующе ждёт ответ. См. дедлок-ловушку в шапке файла — вызывать
    /// только с фоновой очереди, не с делегатной очереди NFC-сессии.
    func transceive(_ frame: Data) throws -> Data {
        guard !poisoned.isSet else {
            throw FrameTimeout()
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        tag.sendMiFareCommand(commandPacket: frame) { data, error in
            box.store(response: error == nil ? data : nil, failure: error)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + Self.frameTimeout) == .success else {
            // Поздний колбэк безопасен: он лишь запишет в box (который больше никто не прочтёт)
            // и просигналит семафор, живущий в его замыкании. `poisoned` не даёт этому соединению
            // отправить ещё одну команду, пока та (возможно всё ещё живая) не разрешится.
            poisoned.set()
            throw FrameTimeout()
        }
        let (response, failure) = box.take()
        if let failure { throw failure }
        return response ?? Data()
    }

    /// Потокобезопасная передача результата из колбэка CoreNFC (делегатная очередь) в ждущий
    /// `transceive` (readQueue): после таймаута колбэк может прийти конкурентно с чтением.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var response: Data?
        private var failure: Error?

        func store(response: Data?, failure: Error?) {
            lock.lock()
            self.response = response
            self.failure = failure
            lock.unlock()
        }

        func take() -> (Data?, Error?) {
            lock.lock()
            defer { lock.unlock() }
            return (response, failure)
        }
    }

    /// Потокобезопасный однонаправленный флаг (снять нельзя): один раз выставленный `poisoned`
    /// остаётся выставленным на всё время жизни соединения к этому тегу.
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }
}
