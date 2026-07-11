//
//  NfcChipScanner.swift
//  kolco24
//
//  Прод-реализация шва `ChipScanning` (Core/Scan/ChipScanning) поверх CoreNFC. Порт ПОВЕДЕНИЯ
//  reader-mode-вайринга из Android (`MainActivity.onTagDiscovered` + `enableReaderMode`), но не
//  структуры: у iOS нет постоянного reader mode, поэтому вместо «чип открывает оверлей» здесь —
//  **одна длинная `NFCTagReaderSession`** на открытый оверлей (решение брейншторма, Technical Details):
//
//  - `start()` открывает системную NFC-шторку; `stop()` инвалидирует её (закрытие оверлея);
//  - `didDetect` → `connect` → UID (`normalizeNfcUid`) → семпл часов ДО чтения (§8) → блокирующий
//    `readRecord` через `MiFareTransport` на выделенной `readQueue` (дедлок-ловушка — см. MiFareTransport)
//    → `TagReading` в стрим → `restartPolling()` для следующего чипа;
//  - дебаунс того же UID ~1.5 с (гасит звуковой спам, редьюсер и так идемпотентен);
//  - 60-с системный лимит iOS (`sessionTimeout`) / ошибка чтения + хост говорит «окно живо» (`shouldRestart`)
//    → молча пересоздаём сессию; поток при этом НЕ завершается (для участника — короткое мигание шторки);
//  - отмена пользователем (`userCanceled`) → завершаем поток (хост закрывает оверлей штатно).
//
//  И скан-оверлей, и bind-лист держат ОДНУ длинную сессию на всё время открытого экрана (bind — порт
//  Android-`DisposableEffect`-хука до `onDispose`): после `poolNotReady`/`notInPool` участник может
//  поднести чип снова, поэтому одноразового режима нет.
//
//  Не-K24 чип (`readRecord` → nil) — валидное чтение браслета участника, НЕ ошибка (§9); различение
//  КП/участник/непривязанный делает `classifyTag` уже в `ScanModel`.
//
//  `import CoreNFC` живёт только под `Nfc/` (grep-инвариант этапа 5).
//

import CoreNFC
import Foundation

/// Источник чтений чипов поверх `NFCTagReaderSession`. Держит изменяемое состояние сессии, поэтому
/// финальный класс; состояние трогается с двух очередей (делегатной CoreNFC и `readQueue`) — защищено
/// `lock`.
final class NfcChipScanner: NSObject, ChipScanning, ProvisioningScanning {

    /// Снимок доверенного времени, берётся ДО блокирующего чтения чипа (§8).
    private let sampleNow: () -> TimeSample
    /// «Окно живо и оверлей открыт?» — хост отвечает через потокобезопасный `ScanLiveness` (читается на
    /// ЭТОЙ делегатной очереди, не с MainActor) на 60-с системном таймауте, чтобы тихо пересоздать сессию,
    /// пока не истекло 20-с окно.
    private let shouldRestart: () -> Bool
    /// Инжектируемый per-tag обработчик «что сделать с подключённым тегом» — выполняется на `readQueue`
    /// (дедлок-дисциплина не меняется). `nil` → дефолтный обработчик (`defaultProcess`), который
    /// воспроизводит текущее поведение (`readRecord` → `TagReading`) и, при активной pending-write ячейке
    /// с совпавшим UID, вместо чтения делает `writeRecord` + read-back (этап 10, провижининг).
    private let process: ((NfcTransport, String, TimeSample) -> TagReading)?

    /// Выделенная очередь для делегатных колбэков сессии (НЕ main).
    private let delegateQueue = DispatchQueue(label: "ru.kolco24.nfc.session")
    /// Выделенная очередь блокирующего `readRecord` — отдельная от делегатной (дедлок-ловушка).
    private let readQueue = DispatchQueue(label: "ru.kolco24.nfc.read")

    private let lock = NSLock()
    private var session: NFCTagReaderSession?
    private var continuation: AsyncStream<TagReading>.Continuation?
    private var finished = false

    /// Дебаунс: последний прочитанный UID и когда.
    private var lastUid: String?
    private var lastReadAt: Date?
    private let debounceInterval: TimeInterval = 1.5

    /// Текущая строка системной шторки (обновляет хост по мере взятия; переприменяется после каждого чтения).
    private var alertMessage = "Приложите чип КП"

    /// pending-write ячейка провижининга (этап 10): UID+запись, ожидающие следующего тапа. Защищена `lock`;
    /// читается ТОЛЬКО обработчиком (`defaultProcess`) на `readQueue` — один механизм, не два. При совпадении
    /// UID обработчик пишет запись; несовпадающий UID → обычное чтение (`writeResult == nil`).
    private var pendingWriteUid: String?
    private var pendingWriteRecord: Data?

    init(
        sampleNow: @escaping () -> TimeSample,
        shouldRestart: @escaping () -> Bool = { false },
        process: ((NfcTransport, String, TimeSample) -> TagReading)? = nil
    ) {
        self.sampleNow = sampleNow
        self.shouldRestart = shouldRestart
        self.process = process
        super.init()
    }

    // MARK: - ChipScanning

    func readings() -> AsyncStream<TagReading> {
        AsyncStream { cont in
            self.lock.lock()
            self.continuation = cont
            self.lock.unlock()
        }
    }

    func start() {
        lock.lock()
        finished = false
        lock.unlock()
        beginSession()
    }

    func stop() {
        lock.lock()
        finished = true
        let s = session
        session = nil
        let cont = continuation
        continuation = nil
        lock.unlock()
        s?.invalidate()
        cont?.finish()
    }

    /// Обновить прогресс в системной шторке (хост `ScanModel` вызывает по мере набора участников:
    /// «Приложите чип КП» / «КП 32 · чипы 2/4» / «Чип не привязан»). Применяется сразу и
    /// переприменяется после следующего чтения (`restartPolling` не сохраняет прежнюю строку).
    func setStatus(_ text: String) {
        lock.lock()
        alertMessage = text
        let s = session
        lock.unlock()
        s?.alertMessage = text
    }

    // MARK: - Провижининг (pending-write ячейка, этап 10)

    /// Вооружить сканер записью: следующий тап по чипу с совпавшим [uid] выполнит `writeRecord` + read-back
    /// (вместо чтения) и вернёт исход в `writeResult` стрима. Чужой UID → обычное чтение, `writeResult == nil`.
    /// Ячейку читает только обработчик на `readQueue`; хост чистит её `clearPendingWrite()` при смене КП/успехе.
    func setPendingWrite(uid: String, record: Data) {
        lock.lock()
        pendingWriteUid = uid
        pendingWriteRecord = record
        lock.unlock()
    }

    /// Разоружить сканер (смена КП / успешная запись / закрытие экрана провижининга). Идемпотентно.
    func clearPendingWrite() {
        lock.lock()
        pendingWriteUid = nil
        pendingWriteRecord = nil
        lock.unlock()
    }

    /// Дефолтный per-tag обработчик (используется, когда `process == nil`): воспроизводит текущее поведение
    /// (`readRecord` → `TagReading`), а при вооружённой pending-write ячейке с совпавшим UID вместо чтения
    /// делает `writeRecord` (header-last + read-back внутри) и кладёт исход в `writeResult`. Один механизм:
    /// несовпадающий UID при активной ячейке → обычное чтение, `writeResult == nil`. Выполняется на `readQueue`.
    private func defaultProcess(_ transport: NfcTransport, _ uid: String, _ sample: TimeSample) -> TagReading {
        lock.lock()
        let pendingUid = pendingWriteUid
        let pendingRecord = pendingWriteRecord
        lock.unlock()
        if let pendingUid, let pendingRecord, pendingUid == uid {
            let result = writeRecord(transport, record: pendingRecord)
            return TagReading(code: nil, uid: uid, sample: sample, writeResult: result)
        }
        let code = readRecord(transport)
        return TagReading(code: code, uid: uid, sample: sample)
    }

    // MARK: - Сессия

    private func beginSession() {
        guard NFCTagReaderSession.readingAvailable else {
            finishStream()
            return
        }
        lock.lock()
        let message = alertMessage
        lock.unlock()
        guard let s = NFCTagReaderSession(
            pollingOption: .iso14443, delegate: self, queue: delegateQueue
        ) else {
            finishStream()
            return
        }
        s.alertMessage = message
        lock.lock()
        // Гонка с stop()/cancelBind(): пока мы собирали новую сессию (рестарт из
        // didInvalidateWithError после 60-с таймаута), хост мог закрыть оверлей — finished стал true,
        // а session уже обнулён и наш invalidate() ушёл в no-op. Публикуем и открываем шторку ТОЛЬКО
        // под тем же lock, если поток ещё жив; иначе сессию-сироту никто не инвалидирует → системная
        // NFC-шторка зависает до перезапуска приложения. Проверка finished и публикация session
        // атомарны относительно lock, поэтому stop() не может вклиниться между ними.
        if finished {
            lock.unlock()
            s.invalidate()
            return
        }
        session = s
        lock.unlock()
        s.begin()
    }

    private func finishStream() {
        lock.lock()
        finished = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.finish()
    }
}

// MARK: - NFCTagReaderSessionDelegate

extension NfcChipScanner: NFCTagReaderSessionDelegate {

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        lock.lock()
        session === self.session ? (self.session = nil) : ()
        let alreadyFinished = finished
        lock.unlock()

        let code = (error as? NFCReaderError)?.code
        // Отмена пользователем (в т.ч. наш собственный `invalidate()` из stop() приходит как
        // userCanceled) → завершаем поток. Хост закрывает оверлей штатно.
        if code == .readerSessionInvalidationErrorUserCanceled {
            finishStream()
            return
        }
        // 60-с лимит iOS / ошибка чтения: если окно ещё живо и оверлей открыт — молча пересоздаём сессию.
        if !alreadyFinished && shouldRestart() {
            beginSession()
            return
        }
        finishStream()
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first, case let .miFare(miFare) = tag else {
            session.restartPolling()
            return
        }
        let uid = normalizeNfcUid(miFare.identifier)

        // Дебаунс того же UID в пределах ~1.5 с (только от звукового спама — редьюсер идемпотентен).
        lock.lock()
        if lastUid == uid, let last = lastReadAt, Date().timeIntervalSince(last) < debounceInterval {
            lock.unlock()
            session.restartPolling()
            return
        }
        lock.unlock()

        // Семпл доверенного времени берётся ДО блокирующего чтения (§8) — время тапа, не пост-I/O.
        let sample = sampleNow()

        session.connect(to: tag) { [weak self] error in
            guard let self else { return }
            if error != nil {
                session.restartPolling()
                return
            }
            // Блокирующее чтение/запись — на readQueue, НЕ на делегатной очереди сессии (дедлок-ловушка).
            // Per-tag шаг вынесен в обработчик: инжектированный `process` или дефолтный (`readRecord`, а при
            // вооружённой pending-write ячейке — `writeRecord`). Session-менеджмент ниже не меняется.
            self.readQueue.async {
                let transport = MiFareTransport(tag: miFare)
                let reading = self.process?(transport, uid, sample)
                    ?? self.defaultProcess(transport, uid, sample)

                self.lock.lock()
                self.lastUid = uid
                self.lastReadAt = Date()
                let cont = self.continuation
                let message = self.alertMessage
                self.lock.unlock()

                cont?.yield(reading)

                // Одна длинная сессия: переприменяем прогресс-строку и продолжаем поллинг следующего чипа.
                session.alertMessage = message
                session.restartPolling()
            }
        }
    }
}
