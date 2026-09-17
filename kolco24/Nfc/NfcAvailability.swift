//
//  NfcAvailability.swift
//  kolco24
//
//  Синхронная проверка доступности NFC-чтения (единственный дом CoreNFC — Nfc/;
//  вьюхи ссылаются на тип напрямую, один модуль — импорт CoreNFC им не нужен).
//  `readingAvailable` статичен в рамках процесса: на всех поддерживаемых iPhone
//  NFC есть и настройками не выключается; false — симулятор / iPad / MDM-запрет.
//

import CoreNFC

enum NfcAvailability {
    static var isReadingAvailable: Bool { NFCTagReaderSession.readingAvailable }
}
