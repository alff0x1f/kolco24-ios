//
//  SecretsTests.swift
//  kolco24Tests
//
//  Смоук-тесты цепочки Config/Secrets.xcconfig → Info.plist → Bundle.main → Secrets.
//  Внимание: сообщения ассертов не должны печатать реальные значения секретов.
//

import Foundation
import Testing
@testable import kolco24

struct SecretsTests {

    // MARK: - Все значения непустые и без неподставленных $(VAR)

    @Test func allValuesAreNonEmpty() {
        #expect(!Secrets.apiBaseURL.isEmpty)
        #expect(!Secrets.appKeyId.isEmpty)
        #expect(!Secrets.appSecret.isEmpty)
        #expect(!Secrets.localAPIBaseURL.isEmpty)
    }

    @Test func noValueContainsUnexpandedVariable() {
        // Реальные значения не печатаем — только факт наличия "$(".
        #expect(!Secrets.apiBaseURL.contains("$("))
        #expect(!Secrets.appKeyId.contains("$("))
        #expect(!Secrets.appSecret.contains("$("))
        #expect(!Secrets.localAPIBaseURL.contains("$("))
    }

    // MARK: - URL-ы: парсятся, схема верная, host непустой

    @Test func apiBaseURLIsValidHTTPSWithHost() throws {
        let url = try #require(URL(string: Secrets.apiBaseURL))
        #expect(url.scheme == "https")
        // Именно host ловит сломанный $()-трюк в xcconfig: обрезанное "https:"
        // парсится как валидный URL со схемой, но без host.
        let host = try #require(url.host)
        #expect(!host.isEmpty)
    }

    @Test func localAPIBaseURLIsValidHTTPWithHost() throws {
        let url = try #require(URL(string: Secrets.localAPIBaseURL))
        #expect(url.scheme == "http")
        let host = try #require(url.host)
        #expect(!host.isEmpty)
    }
}
