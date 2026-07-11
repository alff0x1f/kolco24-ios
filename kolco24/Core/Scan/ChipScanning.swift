//
//  ChipScanning.swift
//  kolco24
//
//  Платформенные швы скан-оверлея: чистое значение одного прочитанного чипа
//  (`TagReading`) и два протокола-границы — источник чтений (`ChipScanning`,
//  реализуется `NfcChipScanner` в задаче 5) и проигрыватель фидбека
//  (`ScanFeedbackPlaying`, реализуется `ScanFeedbackPlayer` в задаче 7).
//
//  Зачем швы, а не типы: `ScanModel` (App/) зависит только от этих протоколов,
//  поэтому остаётся Android-/UIKit-/CoreNFC-free и тестируется `FakeChipScanner`/
//  фидбек-рекордером без железа (конвенция этапов 2–4 — фейк только на
//  платформенной границе, БД реальная). Kotlin-аналога нет: reader-mode-вайринг
//  размазан по `MainActivity`, а здесь он собран в один явный контракт.
//

import Foundation

/// Одно чтение чипа, поднятое сканером в `ScanModel`.
///
/// - `code`: расшифрованный K24-код чипа (`readRecord` → `chipCodeHex`), или `nil`
///   для не-K24 чипа — это валидное чтение браслета участника, **не** ошибка
///   (Technical Details §9). Различение КП/участник/непривязанный делает
///   `classifyTag` уже в редьюсере, не здесь.
/// - `uid`: нормализованный UID тега (`normalizeNfcUid` — сделан сканером до
///   подъёма чтения).
/// - `sample`: снимок `TrustedClock.sample()`, взятый **до** чтения чипа
///   (Technical Details §8) — единый источник времени взятия и монотонного окна.
/// - `writeResult`: итог записи чипа, когда сканер отработал pending-write ячейку
///   провижининга (этап 10) — тап по чипу с совпавшим UID выполняет
///   `writeRecord` + read-back и кладёт исход сюда. `nil` для обычного чтения (и
///   для тапа по чужому UID при активной ячейке — модель тогда покажет «Приложите
///   тот же чип»). Дефолт `nil` в `init` сохраняет существующие construction-sites
///   (`FakeChipScanner`, `ScanModelTests`) без изменений.
struct TagReading: Equatable {
    let code: Data?
    let uid: String
    let sample: TimeSample
    let writeResult: ChipWriteResult?

    init(code: Data?, uid: String, sample: TimeSample, writeResult: ChipWriteResult? = nil) {
        self.code = code
        self.uid = uid
        self.sample = sample
        self.writeResult = writeResult
    }
}

/// Источник чтений чипов — платформенная граница NFC-сессии.
///
/// Одна длинная сессия на оверлей: `start()` открывает системную NFC-шторку,
/// каждое чтение поднимается в `readings()`, `stop()` инвалидирует сессию при
/// закрытии оверлея. Завершение потока `readings()` — это **сигнал окончания
/// сессии не по воле хоста**: пользователь закрыл системную шторку либо NFC
/// недоступен; хост в ответ закрывает оверлей. (Истечение 20-с окна — забота
/// таймера `ScanModel`, а не сканера; 60-с лимит iOS сканер прячет тихим
/// рестартом, поток при этом не завершается.)
///
/// Класс-связанный: реализация держит изменяемое состояние сессии.
protocol ChipScanning: AnyObject {
    /// Поток прочитанных чипов; завершается при отмене пользователем / недоступности NFC.
    func readings() -> AsyncStream<TagReading>
    /// Открыть сессию сканирования (открытие оверлея).
    func start()
    /// Инвалидировать сессию (закрытие оверлея) — идемпотентно.
    func stop()
    /// Прогресс-строка для системной NFC-шторки, которую хост (`ScanModel`) толкает по мере набора
    /// участников («Приложите чип КП» / «КП 32 · чипы 2/4» / диагностика). У `NfcChipScanner` это
    /// `session.alertMessage`; у фейков/превью — no-op (нет системной шторки).
    func setStatus(_ text: String)
}

extension ChipScanning {
    /// По умолчанию — no-op: фейкам/превью нечего показывать (нет системной NFC-шторки).
    func setStatus(_ text: String) {}
}

/// Расширение `ChipScanning` для провижининга (этап 10): pending-write ячейка. Хост
/// (`ProvisioningModel`) вооружает сканер записью на следующий тап (`setPendingWrite`) и
/// разоружает её при смене КП / успешной записи / закрытии экрана (`clearPendingWrite`). Ячейку
/// читает ТОЛЬКО инжектированный обработчик сканера на `readQueue` (один механизм, не два — см.
/// `NfcChipScanner.defaultProcess`): при совпадении UID он делает `writeRecord` + read-back и кладёт
/// исход в `TagReading.writeResult`; несовпадающий UID → обычное чтение (`writeResult == nil`).
/// Реализуется `NfcChipScanner` (Nfc/) и тестовым фейком; обычный скан/судейский/чек-флоу его не
/// требуют (потому это отдельный протокол, а не расширение `ChipScanning` — этап 5 не трогается).
protocol ProvisioningScanning: ChipScanning {
    /// Вооружить сканер записью [record] для следующего тапа по чипу с совпавшим [uid].
    func setPendingWrite(uid: String, record: Data)
    /// Разоружить сканер (смена КП / успешная запись / закрытие экрана). Идемпотентно.
    func clearPendingWrite()
}

/// Проигрыватель аудио/тактильного фидбека скана — платформенная граница
/// (`AVAudioPlayer` + хаптики в задаче 7). Best-effort: любой сбой воспроизведения
/// проглатывается реализацией, никогда не роняет скан-флоу.
protocol ScanFeedbackPlaying {
    /// Проиграть один исход тапа (`success`/`failure`/`neutral`), маппится из
    /// `ScanEvent` через `feedbackFor`.
    func play(_ kind: ScanFeedbackKind)
    /// Фанфары завершения взятия (все участники собраны) — проигрываются хостом
    /// с задержкой `COMPLETE_FANFARE_DELAY_MS` после success на переходе
    /// incomplete→complete.
    func fanfare()
}
