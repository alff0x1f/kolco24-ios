//
//  NfcAvailability.swift
//  kolco24
//
//  Синхронная проверка доступности NFC-чтения (единственный дом CoreNFC — Nfc/;
//  вьюхи ссылаются на тип напрямую, один модуль — импорт CoreNFC им не нужен).
//  `readingAvailable` статичен в рамках процесса: false — симулятор / iPad / MDM-запрет.
//  Выключенное пользователем NFC он НЕ отражает (true), а публичного API для этого нет —
//  узнаём только по `readerErrorRadioDisabled` при старте сессии.
//

import CoreNFC

enum NfcAvailability {
    static var isReadingAvailable: Bool { NFCTagReaderSession.readingAvailable }
}
