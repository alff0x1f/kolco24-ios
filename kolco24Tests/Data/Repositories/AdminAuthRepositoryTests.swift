//
//  AdminAuthRepositoryTests.swift
//  kolco24Tests
//
//  Зеркало сетевой части `AdminAuthRepositoryTest.kt` (login / logout / onUnauthorized / loginOutcome-
//  маппинг — value-часть isExpired/seed/adminErrorMessage покрыта `AdminSessionTests` этапа 2). Гоняется
//  поверх РЕАЛЬНОГО графа `AppEnvironment.inMemory` + `FakeTransport` (Keychain не трогается —
//  admin-стор инъецируется in-memory коробкой, чтобы ассертить его содержимое, как Kotlin `FakeStore`).
//

import Foundation
import Testing
@testable import kolco24

@MainActor
struct AdminAuthRepositoryTests {

    // MARK: - Фикстуры

    /// In-memory фейк `AdminTokenStore` над `Data?`-коробкой — прямой аналог Kotlin `FakeStore`
    /// (`null` save удаляет). Тест держит ссылку, чтобы посидировать и проверить содержимое.
    private final class FakeStore {
        var data: Data?
        init(seed: StoredAdminSession? = nil) {
            if let seed { data = try? JSONEncoder().encode(seed) }
        }
        func store() -> AdminTokenStore {
            AdminTokenStore(load: { [self] in data }, save: { [self] in data = $0 })
        }
        var stored: StoredAdminSession? {
            guard let data else { return nil }
            return try? JSONDecoder().decode(StoredAdminSession.self, from: data)
        }
    }

    private func env(
        _ transport: FakeTransport,
        adminTokenStore: AdminTokenStore? = nil
    ) throws -> AppEnvironment {
        try AppEnvironment.inMemory(transport: transport.handle, adminTokenStore: adminTokenStore)
    }

    // MARK: - loginOutcome (маппинг живёт в репозитории — `Core/` не видит `Net/`)

    @Test
    func loginOutcome_mapsEachBranch() {
        #expect(loginOutcome(PostResult.success(LoginResponse(token: "x", expiresAt: "y"))) == .success)
        #expect(loginOutcome(PostResult<Void>.unauthorized) == .invalidCredentials)
        #expect(loginOutcome(PostResult<Void>.rateLimited) == .rateLimited)
        #expect(loginOutcome(PostResult<Void>.offline) == .offline)
        #expect(loginOutcome(PostResult<Void>.forbidden) == .error)
        #expect(loginOutcome(PostResult<Void>.badRequest) == .error)
        #expect(loginOutcome(PostResult<Void>.conflict) == .error)
        #expect(loginOutcome(PostResult<Void>.error(code: 500)) == .error)
    }

    // MARK: - login

    @Test
    func login_success_persistsAndUpdatesHolder() async throws {
        let transport = FakeTransport()
        transport.enqueue(
            statusCode: 200,
            bodyString: #"{"token":"new-tok","expires_at":"2099-07-21T14:03:00Z"}"#
        )
        let fake = FakeStore()
        let env = try env(transport, adminTokenStore: fake.store())

        let outcome = await env.adminAuthRepository.login(email: "admin@kolco24.ru", password: "s3cret")

        #expect(outcome == .success)
        #expect(env.adminSessionHolder.session
            == .loggedIn(email: "admin@kolco24.ru", token: "new-tok", expiresAt: "2099-07-21T14:03:00Z"))
        #expect(env.adminSessionHolder.token == "new-tok")
        #expect(fake.stored == StoredAdminSession(
            token: "new-tok", email: "admin@kolco24.ru", expiresAt: "2099-07-21T14:03:00Z"))
    }

    @Test
    func login_wrongCredentials_returnsInvalidAndDoesNotPersist() async throws {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 401, bodyString: #"{"detail":"bad"}"#)
        let fake = FakeStore()
        let env = try env(transport, adminTokenStore: fake.store())

        let outcome = await env.adminAuthRepository.login(email: "a@b.ru", password: "nope")

        #expect(outcome == .invalidCredentials)
        #expect(env.adminSessionHolder.session == .loggedOut)
        #expect(env.adminSessionHolder.token == nil)
        #expect(fake.stored == nil)
    }

    @Test
    func login_rateLimited_returnsRateLimited_andDoesNotPersist() async throws {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 429)
        let fake = FakeStore()
        let env = try env(transport, adminTokenStore: fake.store())

        let outcome = await env.adminAuthRepository.login(email: "a@b.ru", password: "x")

        #expect(outcome == .rateLimited)
        #expect(env.adminSessionHolder.session == .loggedOut)
        #expect(fake.stored == nil)
    }

    @Test
    func login_offline_returnsOffline_andDoesNotPersist() async throws {
        let transport = FakeTransport()
        transport.enqueueError(URLError(.notConnectedToInternet))
        let fake = FakeStore()
        let env = try env(transport, adminTokenStore: fake.store())

        let outcome = await env.adminAuthRepository.login(email: "a@b.ru", password: "x")

        #expect(outcome == .offline)
        #expect(env.adminSessionHolder.session == .loggedOut)
        #expect(fake.stored == nil)
    }

    // MARK: - logout / onUnauthorized

    @Test
    func logout_clearsLocally_evenWhenOffline() async throws {
        let transport = FakeTransport()
        transport.enqueueError(URLError(.notConnectedToInternet))
        let fake = FakeStore(seed: StoredAdminSession(
            token: "tok", email: "a@b.ru", expiresAt: "2099-01-01T00:00:00Z"))
        let env = try env(transport, adminTokenStore: fake.store())
        // Посидированная живая сессия.
        #expect(env.adminSessionHolder.session
            == .loggedIn(email: "a@b.ru", token: "tok", expiresAt: "2099-01-01T00:00:00Z"))

        await env.adminAuthRepository.logout()

        #expect(env.adminSessionHolder.session == .loggedOut)
        #expect(env.adminSessionHolder.token == nil)
        #expect(fake.stored == nil)
    }

    @Test
    func logout_clearsLocally_whenServerSucceeds() async throws {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200)
        let fake = FakeStore(seed: StoredAdminSession(
            token: "tok", email: "a@b.ru", expiresAt: "2099-01-01T00:00:00Z"))
        let env = try env(transport, adminTokenStore: fake.store())

        await env.adminAuthRepository.logout()

        #expect(env.adminSessionHolder.session == .loggedOut)
        #expect(fake.stored == nil)
    }

    @Test
    func onUnauthorized_clearsStoreAndSession() throws {
        let transport = FakeTransport()
        let fake = FakeStore(seed: StoredAdminSession(
            token: "tok", email: "a@b.ru", expiresAt: "2099-01-01T00:00:00Z"))
        let env = try env(transport, adminTokenStore: fake.store())
        #expect(env.adminSessionHolder.token == "tok")

        env.adminAuthRepository.onUnauthorized()

        #expect(env.adminSessionHolder.session == .loggedOut)
        #expect(env.adminSessionHolder.token == nil)
        #expect(fake.stored == nil)
    }

    // MARK: - сид сессии (через граф — deviation: seed живёт в holder, `AppEnvironment` его зовёт)

    @Test
    func seed_pastExpiry_isLoggedOut_andClearsStore() throws {
        let transport = FakeTransport()
        let fake = FakeStore(seed: StoredAdminSession(
            token: "tok", email: "a@b.ru", expiresAt: "2000-01-01T00:00:00Z"))
        let env = try env(transport, adminTokenStore: fake.store())

        #expect(env.adminSessionHolder.session == .loggedOut)
        #expect(env.adminSessionHolder.token == nil)
        #expect(fake.stored == nil)
    }
}
