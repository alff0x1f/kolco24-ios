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
final class NfcChipScanner: NSObject, ChipScanning {

    /// Снимок доверенного времени, берётся ДО блокирующего чтения чипа (§8).
    private let sampleNow: () -> TimeSample
    /// «Окно живо и оверлей открыт?» — хост отвечает через потокобезопасный `ScanLiveness` (читается на
    /// ЭТОЙ делегатной очереди, не с MainActor) на 60-с системном таймауте, чтобы тихо пересоздать сессию,
    /// пока не истекло 20-с окно.
    private let shouldRestart: () -> Bool

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

    init(
        sampleNow: @escaping () -> TimeSample,
        shouldRestart: @escaping () -> Bool = { false }
    ) {
        self.sampleNow = sampleNow
        self.shouldRestart = shouldRestart
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
            // Блокирующее чтение — на readQueue, НЕ на делегатной очереди сессии (дедлок-ловушка).
            self.readQueue.async {
                let code = readRecord(MiFareTransport(tag: miFare))
                let reading = TagReading(code: code, uid: uid, sample: sample)

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
