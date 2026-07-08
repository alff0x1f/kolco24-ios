//
//  InfoPlistTests.swift
//  kolco24Tests
//
//  Смоук-тесты слитого Info.plist (частичный kolco24/Info.plist + генерируемые
//  ключи, GENERATE_INFOPLIST_FILE = YES). Тесты хостятся в приложении, поэтому
//  Bundle.main — это бандл приложения с итоговым plist.
//

import Foundation
import Testing

struct InfoPlistTests {

    @Test func atsAllowsLocalNetworking() throws {
        let ats = try #require(
            Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        )
        let allowsLocalNetworking = try #require(ats["NSAllowsLocalNetworking"] as? Bool)
        #expect(allowsLocalNetworking)
    }

    @Test func localNetworkUsageDescriptionIsPresent() throws {
        // Обязателен для доступа к локальной сети (TN3179): без purpose string
        // системный промпт при первом трафике к LAN-серверу гонки (этап 3)
        // остаётся без объяснения для пользователя.
        let usage = try #require(
            Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String
        )
        #expect(!usage.isEmpty)
    }

    @Test func generatedKeysSurviveMergeWithPartialPlist() throws {
        // NFCReaderUsageDescription приходит из генерируемой части plist;
        // регресс слияния (например, GENERATE_INFOPLIST_FILE = NO) молча
        // сломал бы NFC-сканирование.
        let nfcUsage = try #require(
            Bundle.main.object(forInfoDictionaryKey: "NFCReaderUsageDescription") as? String
        )
        #expect(!nfcUsage.isEmpty)
    }
}
