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

    private func seedJson(token: String, email: String, expiresAt: String, adminRaceIds: [Int] = []) -> Data {
        try! JSONEncoder().encode(
            StoredAdminSession(token: token, email: email, expiresAt: expiresAt, adminRaceIds: adminRaceIds)
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
        let fake = FakeStore(seed: seedJson(
            token: "tok-xyz", email: "admin@kolco24.ru", expiresAt: "2099-01-01T00:00:00Z", adminRaceIds: [3, 7]
        ))
        let session = AdminSessionHolder.seed(store: store(fake), nowUtcIso: "2026-01-01T00:00:00Z")

        #expect(session == .loggedIn(
            email: "admin@kolco24.ru", token: "tok-xyz", expiresAt: "2099-01-01T00:00:00Z", adminRaceIds: [3, 7]
        ))
        #expect(fake.data != nil) // живая сессия не тронута
    }

    @Test
    func seed_emptyStore_isLoggedOut() {
        let fake = FakeStore()
        let session = AdminSessionHolder.seed(store: store(fake), nowUtcIso: "2026-01-01T00:00:00Z")
        #expect(session == .loggedOut)
    }

    // MARK: - isRaceAdmin

    private func admin(_ ids: [Int]) -> AdminSession {
        .loggedIn(email: "a@b.ru", token: "t", expiresAt: "2099-01-01T00:00:00Z", adminRaceIds: ids)
    }

    @Test func isRaceAdmin_cloudOnly() {
        #expect(isRaceAdmin(raceId: 3, cloud: admin([3, 7]), local: .loggedOut))
    }

    @Test func isRaceAdmin_lanOnly() {
        #expect(isRaceAdmin(raceId: 7, cloud: admin([]), local: admin([7])))
    }

    @Test func isRaceAdmin_inNeither() {
        #expect(!isRaceAdmin(raceId: 5, cloud: admin([3]), local: admin([7])))
    }

    @Test func isRaceAdmin_emptyLists() {
        #expect(!isRaceAdmin(raceId: 3, cloud: admin([]), local: admin([])))
    }

    @Test func isRaceAdmin_bothLoggedOut() {
        #expect(!isRaceAdmin(raceId: 3, cloud: .loggedOut, local: .loggedOut))
    }

    // MARK: - combinedLoginOutcome

    @Test func combinedLoginOutcome_emptyIsError() {
        #expect(combinedLoginOutcome([]) == .error)
    }

    @Test func combinedLoginOutcome_singlePassesThrough() {
        #expect(combinedLoginOutcome([.offline]) == .offline)
        #expect(combinedLoginOutcome([.rateLimited]) == .rateLimited)
    }

    @Test func combinedLoginOutcome_anySuccessWins() {
        #expect(combinedLoginOutcome([.invalidCredentials, .success]) == .success)
        #expect(combinedLoginOutcome([.success, .offline]) == .success)
    }

    @Test func combinedLoginOutcome_realAnswerBeatsOffline() {
        #expect(combinedLoginOutcome([.offline, .invalidCredentials]) == .invalidCredentials)
        #expect(combinedLoginOutcome([.offline, .rateLimited]) == .rateLimited)
        #expect(combinedLoginOutcome([.error, .offline]) == .error)
        #expect(combinedLoginOutcome([.offline, .offline]) == .offline)
    }

    @Test func combinedLoginOutcome_invalidCredentialsBeatsRateLimited() {
        #expect(combinedLoginOutcome([.rateLimited, .invalidCredentials]) == .invalidCredentials)
    }

    // MARK: - adminRowSubtitle / adminNoSessionMessage

    @Test func adminRowSubtitle_eachCombination() {
        let cloud = AdminSession.loggedIn(email: "c@x.ru", token: "t1", expiresAt: "2099-01-01T00:00:00Z", adminRaceIds: [])
        let lan = AdminSession.loggedIn(email: "l@x.ru", token: "t2", expiresAt: "2099-01-01T00:00:00Z", adminRaceIds: [])
        #expect(adminRowSubtitle(cloud: cloud, local: lan) == "c@x.ru")
        #expect(adminRowSubtitle(cloud: cloud, local: .loggedOut) == "c@x.ru · только Cloud")
        #expect(adminRowSubtitle(cloud: .loggedOut, local: lan) == "l@x.ru · только LAN")
        #expect(adminRowSubtitle(cloud: .loggedOut, local: .loggedOut) == "Войти")
    }

    @Test func adminNoSessionMessage_perServer() {
        #expect(adminNoSessionMessage(.cloud) == "Нет входа на cloud-сервер")
        #expect(adminNoSessionMessage(.lan) == "Нет входа на LAN-сервер")
    }
}
