import CoreNFC
import Foundation

// MARK: - Result
enum ChipReadResult {
    case success(uid: String, codeHex: String?) // codeHex == nil → на чипе нет записи K24
    case failure(String)
}

// MARK: - NFCChipReader
/// Тестовый спайк: одноразовая NFC-сессия, читает UID и K24-код чипа
/// (страницы 4–8: магия "K24" + байт версии/типа + 16 байт кода),
/// зеркалит readChipCode из Android MifareUltralightWriter.
final class NFCChipReader: NSObject, NFCTagReaderSessionDelegate {
    private var session: NFCTagReaderSession?
    private var completion: ((ChipReadResult) -> Void)?
    private var finished = false

    func beginScan(completion: @escaping (ChipReadResult) -> Void) {
        guard NFCTagReaderSession.readingAvailable else {
            completion(.failure("NFC недоступен на этом устройстве"))
            return
        }
        self.completion = completion
        finished = false
        session = NFCTagReaderSession(pollingOption: .iso14443, delegate: self)
        session?.alertMessage = "Поднесите телефон к чипу КП"
        session?.begin()
    }

    // MARK: NFCTagReaderSessionDelegate
    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        let nfcError = error as? NFCReaderError
        if nfcError?.code == .readerSessionInvalidationErrorUserCanceled {
            finish(.failure("Сканирование отменено"))
        } else {
            finish(.failure(error.localizedDescription))
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first else { return }
        guard case let .miFare(miFare) = tag else {
            session.invalidate(errorMessage: "Неподдерживаемый тип метки")
            return
        }
        session.connect(to: tag) { [weak self] error in
            guard let self else { return }
            if let error {
                session.invalidate(errorMessage: error.localizedDescription)
                return
            }
            let uid = Self.hex(miFare.identifier)
            self.readPages4to8(miFare) { data in
                session.alertMessage = "Готово"
                session.invalidate()
                self.finish(.success(uid: uid, codeHex: Self.parseK24Code(data)))
            }
        }
    }

    // MARK: Chip commands
    /// FAST_READ (0x3A) страниц 4–8 (20 байт), при ошибке — fallback
    /// на два обычных READ (0x30), как в Android-версии.
    private func readPages4to8(_ tag: NFCMiFareTag, done: @escaping (Data?) -> Void) {
        tag.sendMiFareCommand(commandPacket: Data([0x3A, 0x04, 0x08])) { [weak self] data, error in
            if error == nil, data.count >= 20 {
                done(data)
            } else {
                self?.readPagesFallback(tag, done: done)
            }
        }
    }

    private func readPagesFallback(_ tag: NFCMiFareTag, done: @escaping (Data?) -> Void) {
        tag.sendMiFareCommand(commandPacket: Data([0x30, 0x04])) { first, error in
            guard error == nil, first.count >= 16 else {
                done(nil)
                return
            }
            tag.sendMiFareCommand(commandPacket: Data([0x30, 0x08])) { second, error in
                guard error == nil, second.count >= 4 else {
                    done(nil)
                    return
                }
                done(first + second.prefix(4))
            }
        }
    }

    /// Страницы 4–8: "K24" + (version<<4 | type) + 16 байт кода.
    private static func parseK24Code(_ data: Data?) -> String? {
        guard let data, data.count >= 20,
              data[data.startIndex] == UInt8(ascii: "K"),
              data[data.startIndex + 1] == UInt8(ascii: "2"),
              data[data.startIndex + 2] == UInt8(ascii: "4")
        else { return nil }
        return hex(data.subdata(in: (data.startIndex + 4)..<(data.startIndex + 20)))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined()
    }

    private func finish(_ result: ChipReadResult) {
        guard !finished else { return }
        finished = true
        session = nil
        let completion = self.completion
        self.completion = nil
        DispatchQueue.main.async { completion?(result) }
    }
}
