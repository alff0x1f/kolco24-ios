//
//  AdminSessionTests.swift
//  kolco24Tests
//
//  Зеркало value-части `AdminAuthRepositoryTest.kt` (только isExpired / seed / adminErrorMessage —
//  сетевые login/logout/onUnauthorized-кейсы зеркалятся в Task 4 `AdminAuthRepositoryTests`).
//  Адаптация под iOS: `seedSession` переехал в `AdminSessionHolder.seed`; `adminErrorMessage`
//  возвращает `String?` (success → nil) вместо Kotlin-"".
//

import Foundation
import Testing
@testable import kolco24

struct AdminSessionTests {

    /// In-memory одноитемный store (идиома `AdminTokenStoreTests`).
    private final class FakeStore {
        var data: Data?
        init(seed: Data? = nil) { self.data = seed }
        func load() -> Data? { data }
        func save(_ value: Data?) { data = value }
    }

    private func store(_ fake: FakeStore) -> AdminTokenStore {
        AdminTokenStore(load: fake.load, save: fake.save)
    }

    private func seedJson(token: String, email: String, expiresAt: String) -> Data {
        try! JSONEncoder().encode(
            StoredAdminSession(token: token, email: email, expiresAt: expiresAt)
        )
    }

    // MARK: isExpired

    @Test
    func isExpired_pastIsTrue_futureIsFalse_boundaryIsExpired() {
        let now = "2026-06-21T12:00:00Z"
        #expect(isExpired(expiresAt: "2026-06-21T11:59:59Z", nowUtcIso: now)) // истёк до now → истёк
        #expect(!isExpired(expiresAt: "2026-06-21T12:00:01Z", nowUtcIso: now)) // истекает после → жив
        #expect(isExpired(expiresAt: "2026-06-21T12:00:00Z", nowUtcIso: now)) // точная граница → истёк
    }

    @Test
    func nowUtcIso_formatsFixedWidthUtc() {
        // 2026-01-02T03:04:05Z в epoch-секундах.
        let date = Date(timeIntervalSince1970: 1_767_323_045)
        #expect(nowUtcIso(date) == "2026-01-02T03:04:05Z")
    }

    // MARK: adminErrorMessage

    @Test
    func adminErrorMessage_strings() {
        #expect(adminErrorMessage(.success) == nil)
        #expect(adminErrorMessage(.invalidCredentials) == "Неверный email или пароль")
        #expect(adminErrorMessage(.rateLimited) == "Слишком много попыток входа. Попробуйте позже")
        #expect(adminErrorMessage(.offline) == "Нет соединения с сервером")
        #expect(adminErrorMessage(.error) == "Не удалось войти. Попробуйте ещё раз")
    }

    // MARK: seed

    @Test
    func seed_pastExpiry_isLoggedOut_andClearsStore() {
        let fake = FakeStore(seed: seedJson(token: "tok", email: "a@b.ru", expiresAt: "2025-01-01T00:00:00Z"))
        let session = AdminSessionHolder.seed(store: store(fake), nowUtcIso: "2026-01-01T00:00:00Z")

        #expect(session == .loggedOut)
        #expect(fake.data == nil) // store очищен
    }

    @Test
    func seed_futureExpiry_isLoggedIn() {
        let fake = FakeStore(seed: seedJson(token: "tok-xyz", email: "admin@kolco24.ru", expiresAt: "2099-01-01T00:00:00Z"))
        let session = AdminSessionHolder.seed(store: store(fake), nowUtcIso: "2026-01-01T00:00:00Z")

        #expect(session == .loggedIn(email: "admin@kolco24.ru", token: "tok-xyz", expiresAt: "2099-01-01T00:00:00Z"))
        #expect(fake.data != nil) // живая сессия не тронута
    }

    @Test
    func seed_emptyStore_isLoggedOut() {
        let fake = FakeStore()
        let session = AdminSessionHolder.seed(store: store(fake), nowUtcIso: "2026-01-01T00:00:00Z")
        #expect(session == .loggedOut)
    }
}
