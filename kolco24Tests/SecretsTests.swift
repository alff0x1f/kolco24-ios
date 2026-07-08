//
//  SecretsTests.swift
//  kolco24Tests
//
//  Смоук-тесты цепочки Config/Secrets.xcconfig → Info.plist → Bundle.main → Secrets.
//  Внимание: сообщения ассертов не должны печатать реальные значения секретов —
//  сравнения с секретами считаем в локальные булевы до #expect.
//

import Foundation
import Testing
@testable import kolco24

struct SecretsTests {

    // MARK: - Непустота

    @Test func allValuesAreNonEmpty() {
        #expect(!Secrets.apiBaseURL.isEmpty)
        #expect(!Secrets.appKeyId.isEmpty)
        #expect(!Secrets.appSecret.isEmpty)
        #expect(!Secrets.localAPIBaseURL.isEmpty)
    }

    // MARK: - Плейсхолдеры

    @Test func valuesAreNotExamplePlaceholders() throws {
        // Дословная копия Secrets.example.xcconfig проходит остальные проверки
        // (плейсхолдеры непустые, https://api.example.com — валидный URL с host),
        // поэтому ловим их явно. При провале #expect печатает только плейсхолдер,
        // не реальный секрет.
        let url = try #require(URL(string: Secrets.apiBaseURL))
        #expect(url.host(percentEncoded: false) != "api.example.com")
        let keyIdIsPlaceholder = Secrets.appKeyId == "your-app-key-id"
        #expect(!keyIdIsPlaceholder)
        let secretIsPlaceholder = Secrets.appSecret == "your-hex-secret"
        #expect(!secretIsPlaceholder)
    }

    // MARK: - URL

    @Test func apiBaseURLIsValidHTTPSWithHost() throws {
        let url = try #require(URL(string: Secrets.apiBaseURL))
        #expect(url.scheme == "https")
        // Именно host ловит сломанный $()-трюк в xcconfig: обрезанное "https:"
        // парсится как валидный URL со схемой, но без host.
        let host = try #require(url.host(percentEncoded: false))
        #expect(!host.isEmpty)
    }

    @Test func localAPIBaseURLIsValidHTTPWithHost() throws {
        let url = try #require(URL(string: Secrets.localAPIBaseURL))
        #expect(url.scheme == "http")
        let host = try #require(url.host(percentEncoded: false))
        #expect(!host.isEmpty)
    }

    // MARK: - value(forInfoPlistKey:in:)

    @Test func valueLookupReturnsNonEmptyString() {
        let info: [String: Any] = ["Key": "value"]
        #expect(Secrets.value(forInfoPlistKey: "Key", in: info) == "value")
    }

    @Test func valueLookupRejectsMissingEmptyAndNonString() {
        #expect(Secrets.value(forInfoPlistKey: "Missing", in: [:]) == nil)
        #expect(Secrets.value(forInfoPlistKey: "Empty", in: ["Empty": ""]) == nil)
        #expect(Secrets.value(forInfoPlistKey: "Number", in: ["Number": 42]) == nil)
    }

    @Test func valueLookupRejectsUnexpandedBuildSettingLiteral() {
        // Xcode разворачивает неопределённую переменную в пустую строку,
        // но шов отвергает и сырой литерал — на случай plist, собранного
        // в обход подстановки. Литерал — плейсхолдер, не секрет.
        #expect(Secrets.value(forInfoPlistKey: "Raw", in: ["Raw": "$(APP_SECRET)"]) == nil)
        #expect(Secrets.value(forInfoPlistKey: "Partial", in: ["Partial": "https://$(HOST)/api"]) == nil)
    }
}
