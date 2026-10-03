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
        #expect(loginOutcome(PostResult.success(LoginResponse(token: "x", expiresAt: "y", adminRaceIds: []))) == .success)
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
            bodyString: #"{"token":"new-tok","expires_at":"2099-07-21T14:03:00Z","admin_race_ids":[3,7]}"#
        )
        let fake = FakeStore()
        let env = try env(transport, adminTokenStore: fake.store())

        let outcome = await env.cloudAdminAuth.login(email: "admin@kolco24.ru", password: "s3cret")

        #expect(outcome == .success)
        #expect(env.cloudAdminSession.session
            == .loggedIn(email: "admin@kolco24.ru", token: "new-tok", expiresAt: "2099-07-21T14:03:00Z", adminRaceIds: [3, 7]))
        #expect(env.cloudAdminSession.token == "new-tok")
        #expect(fake.stored == StoredAdminSession(
            token: "new-tok", email: "admin@kolco24.ru", expiresAt: "2099-07-21T14:03:00Z", adminRaceIds: [3, 7]))
    }

    @Test
    func login_wrongCredentials_returnsInvalidAndDoesNotPersist() async throws {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 401, bodyString: #"{"detail":"bad"}"#)
        let fake = FakeStore()
        let env = try env(transport, adminTokenStore: fake.store())

        let outcome = await env.cloudAdminAuth.login(email: "a@b.ru", password: "nope")

        #expect(outcome == .invalidCredentials)
        #expect(env.cloudAdminSession.session == .loggedOut)
        #expect(env.cloudAdminSession.token == nil)
        #expect(fake.stored == nil)
    }

    @Test
    func login_rateLimited_returnsRateLimited_andDoesNotPersist() async throws {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 429)
        let fake = FakeStore()
        let env = try env(transport, adminTokenStore: fake.store())

        let outcome = await env.cloudAdminAuth.login(email: "a@b.ru", password: "x")

        #expect(outcome == .rateLimited)
        #expect(env.cloudAdminSession.session == .loggedOut)
        #expect(fake.stored == nil)
    }

    @Test
    func login_offline_returnsOffline_andDoesNotPersist() async throws {
        let transport = FakeTransport()
        transport.enqueueError(URLError(.notConnectedToInternet))
        let fake = FakeStore()
        let env = try env(transport, adminTokenStore: fake.store())

        let outcome = await env.cloudAdminAuth.login(email: "a@b.ru", password: "x")

        #expect(outcome == .offline)
        #expect(env.cloudAdminSession.session == .loggedOut)
        #expect(fake.stored == nil)
    }

    // MARK: - logout / onUnauthorized

    @Test
    func logout_clearsLocally_evenWhenOffline() async throws {
        let transport = FakeTransport()
        transport.enqueueError(URLError(.notConnectedToInternet))
        let fake = FakeStore(seed: StoredAdminSession(
            token: "tok", email: "a@b.ru", expiresAt: "2099-01-01T00:00:00Z", adminRaceIds: []))
        let env = try env(transport, adminTokenStore: fake.store())
        // Посидированная живая сессия.
        #expect(env.cloudAdminSession.session
            == .loggedIn(email: "a@b.ru", token: "tok", expiresAt: "2099-01-01T00:00:00Z", adminRaceIds: []))

        await env.cloudAdminAuth.logout()

        #expect(env.cloudAdminSession.session == .loggedOut)
        #expect(env.cloudAdminSession.token == nil)
        #expect(fake.stored == nil)
    }

    @Test
    func logout_clearsLocally_whenServerSucceeds() async throws {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200)
        let fake = FakeStore(seed: StoredAdminSession(
            token: "tok", email: "a@b.ru", expiresAt: "2099-01-01T00:00:00Z", adminRaceIds: []))
        let env = try env(transport, adminTokenStore: fake.store())

        await env.cloudAdminAuth.logout()

        #expect(env.cloudAdminSession.session == .loggedOut)
        #expect(fake.stored == nil)
    }

    @Test
    func onUnauthorized_clearsStoreAndSession() throws {
        let transport = FakeTransport()
        let fake = FakeStore(seed: StoredAdminSession(
            token: "tok", email: "a@b.ru", expiresAt: "2099-01-01T00:00:00Z", adminRaceIds: []))
        let env = try env(transport, adminTokenStore: fake.store())
        #expect(env.cloudAdminSession.token == "tok")

        env.cloudAdminAuth.onUnauthorized()

        #expect(env.cloudAdminSession.session == .loggedOut)
        #expect(env.cloudAdminSession.token == nil)
        #expect(fake.stored == nil)
    }

    // MARK: - сид сессии (через граф — deviation: seed живёт в holder, `AppEnvironment` его зовёт)

    @Test
    func seed_pastExpiry_isLoggedOut_andClearsStore() throws {
        let transport = FakeTransport()
        let fake = FakeStore(seed: StoredAdminSession(
            token: "tok", email: "a@b.ru", expiresAt: "2000-01-01T00:00:00Z", adminRaceIds: []))
        let env = try env(transport, adminTokenStore: fake.store())

        #expect(env.cloudAdminSession.session == .loggedOut)
        #expect(env.cloudAdminSession.token == nil)
        #expect(fake.stored == nil)
    }
    // MARK: - login в полёте во время logout

    /// Транспорт, подвешивающий запрос до `release()`: ответ login'а приходит ПОСЛЕ logout'а.
    private final class GatedTransport: @unchecked Sendable {
        private let lock = NSLock()
        private var gate: CheckedContinuation<Void, Never>?
        private(set) var requests: [URLRequest] = []
        var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return gate != nil }

        func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            await withCheckedContinuation { cont in
                lock.lock(); requests.append(request); gate = cont; lock.unlock()
            }
            let body = Data(#"{"token":"late-tok","expires_at":"2099-07-21T14:03:00Z"}"#.utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        func release() {
            lock.lock(); let g = gate; gate = nil; lock.unlock()
            g?.resume()
        }
    }

    @Test
    func login_inFlightDuringLogout_doesNotResurrectSession() async throws {
        let transport = GatedTransport()
        let fake = FakeStore()
        let env = try AppEnvironment.inMemory(transport: transport.handle, adminTokenStore: fake.store())
        let repo = env.cloudAdminAuth

        let login = Task { await repo.login(email: "admin@kolco24.ru", password: "s3cret") }
        while !transport.isHeld { try await Task.sleep(for: .milliseconds(5)) }
        await repo.logout()
        transport.release()

        #expect(await login.value == .error)
        #expect(env.cloudAdminSession.session == .loggedOut)
        #expect(fake.stored == nil)
        #expect(transport.requests.count == 1) // logout без сессии — без запроса
    }

    @Test
    func logout_whenLoggedOut_makesNoRequest() async throws {
        let transport = FakeTransport()
        let env = try env(transport)

        await env.cloudAdminAuth.logout()

        #expect(transport.callCount == 0)
        #expect(env.cloudAdminSession.session == .loggedOut)
    }

    // MARK: - две сессии: cloud / LAN

    @Test
    func sessionsAreIndependent_localLoginDoesNotTouchCloud() async throws {
        let transport = FakeTransport()
        transport.enqueue(
            statusCode: 200,
            bodyString: #"{"token":"lan-tok","expires_at":"2099-07-21T14:03:00Z","admin_race_ids":[7]}"#
        )
        let cloudStore = FakeStore()
        let localStore = FakeStore()
        let env = try AppEnvironment.inMemory(
            transport: transport.handle,
            adminTokenStore: cloudStore.store(),
            localAdminTokenStore: localStore.store()
        )

        #expect(await env.localAdminAuth.login(email: "a@b.ru", password: "x") == .success)

        #expect(transport.last?.url?.absoluteString.hasPrefix("http://local.test") == true)
        #expect(env.localAdminSession.token == "lan-tok")
        #expect(localStore.stored?.token == "lan-tok")
        #expect(localStore.stored?.adminRaceIds == [7])
        #expect(env.localAdminSession.session
            == .loggedIn(email: "a@b.ru", token: "lan-tok", expiresAt: "2099-07-21T14:03:00Z", adminRaceIds: [7]))
        #expect(env.cloudAdminSession.session == .loggedOut)
        #expect(cloudStore.stored == nil)
    }

    // MARK: - bearer по клиентам

    private func loggedInEnv(_ transport: FakeTransport) throws -> AppEnvironment {
        let cloud = FakeStore(seed: StoredAdminSession(token: "cloud-tok", email: "a@b.ru", expiresAt: "2099-01-01T00:00:00Z", adminRaceIds: []))
        let local = FakeStore(seed: StoredAdminSession(token: "lan-tok", email: "a@b.ru", expiresAt: "2099-01-01T00:00:00Z", adminRaceIds: []))
        return try AppEnvironment.inMemory(
            transport: transport.handle,
            adminTokenStore: cloud.store(),
            localAdminTokenStore: local.store()
        )
    }

    @Test
    func eachClientSendsOnlyItsOwnToken_lanOnlyWhileLeaseActive() async throws {
        let transport = FakeTransport()
        for _ in 0..<3 { transport.enqueue(statusCode: 500) }
        let env = try loggedInEnv(transport)
        let farFuture = Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000

        _ = await env.bindTag(.cloud, 8, 1, "04AA")
        _ = await env.bindTag(.lan, 8, 1, "04AA") // lease нет — LAN-токен не уходит
        env.leaseHolder.set(RaceLease(raceId: 99, expiresAtMs: farFuture))
        _ = await env.bindTag(.lan, 8, 1, "04AA")

        let auth = transport.recorded.map { $0.value(forHTTPHeaderField: "Authorization") }
        #expect(transport.recorded[0].url?.host == "cloud.test")
        #expect(auth[0] == "Bearer cloud-tok")
        #expect(transport.recorded[1].url?.host == "local.test")
        #expect(auth[1] == nil)
        #expect(auth[2] == "Bearer lan-tok")
    }

    @Test
    func adminRoute_followsRacePin() throws {
        let env = try loggedInEnv(FakeTransport())
        #expect(env.adminRoute(raceId: 8).server == .cloud)

        let farFuture = Int64(Date().timeIntervalSince1970 * 1000) + 3_600_000
        env.leaseHolder.set(RaceLease(raceId: 8, expiresAtMs: farFuture))
        let route = env.adminRoute(raceId: 8)
        #expect(route.server == .lan)
        #expect(route.hasSession)
        #expect(env.adminRoute(raceId: 9).server == .cloud)

        route.onUnauthorized()
        #expect(env.localAdminSession.session == .loggedOut)
        #expect(env.cloudAdminSession.token == "cloud-tok")
        #expect(!env.adminRoute(raceId: 8).hasSession)
    }
}
