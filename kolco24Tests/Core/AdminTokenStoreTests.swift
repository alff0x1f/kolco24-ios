//
//  AdminTokenStoreTests.swift
//  kolco24Tests
//
//  Зеркало `data/AdminTokenStoreTest.kt` — адаптировано под iOS-однокомпонентный JSON-item
//  (`load: () -> Data?` / `save: (Data?) -> Void`) вместо трёхключевого Android-store:
//  round-trip write/read/clear, pre-seeded read, `nil` при отсутствии/пустом любом поле.
//  Свежие кейсы: битый JSON → nil; write поверх старого item заменяет целиком.
//

import Foundation
import Testing
@testable import kolco24

struct AdminTokenStoreTests {

    /// In-memory фейк инъецированного одноитемного store; `nil`-save удаляет значение.
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

    @Test
    func read_returnsNil_whenStoreEmpty() {
        let fake = FakeStore()
        #expect(store(fake).read() == nil)
    }

    @Test
    func write_thenRead_roundTrips() {
        let fake = FakeStore()
        let s = store(fake)
        let session = StoredAdminSession(
            token: "tok123", email: "admin@kolco24.ru", expiresAt: "2026-07-21T14:03:00Z"
        )

        s.write(session)

        #expect(s.read() == session)
    }

    @Test
    func read_reflectsPreSeededStore() {
        let fake = FakeStore(
            seed: seedJson(token: "seeded", email: "pre@seed.ru", expiresAt: "2026-08-01T00:00:00Z")
        )
        #expect(store(fake).read() == StoredAdminSession(
            token: "seeded", email: "pre@seed.ru", expiresAt: "2026-08-01T00:00:00Z"
        ))
    }

    @Test
    func clear_removesItem() {
        let fake = FakeStore()
        let s = store(fake)
        s.write(StoredAdminSession(token: "tok", email: "a@b.ru", expiresAt: "2026-07-21T14:03:00Z"))

        s.clear()

        #expect(s.read() == nil)
        #expect(fake.data == nil)
    }

    @Test
    func read_returnsNil_whenExpiryEmpty() {
        let fake = FakeStore(seed: seedJson(token: "tok", email: "a@b.ru", expiresAt: ""))
        #expect(store(fake).read() == nil)
    }

    @Test
    func read_returnsNil_whenTokenEmpty() {
        let fake = FakeStore(seed: seedJson(token: "", email: "a@b.ru", expiresAt: "2099-01-01T00:00:00Z"))
        #expect(store(fake).read() == nil)
    }

    @Test
    func read_returnsNil_whenEmailEmpty() {
        let fake = FakeStore(seed: seedJson(token: "tok", email: "", expiresAt: "2099-01-01T00:00:00Z"))
        #expect(store(fake).read() == nil)
    }

    @Test
    func read_returnsNil_whenGarbageJson() {
        let fake = FakeStore(seed: Data("not json {".utf8))
        #expect(store(fake).read() == nil)
    }

    @Test
    func read_returnsNil_whenMissingField() {
        // Валидный JSON, но без ключа expiresAt — Codable-декод падает → nil.
        let fake = FakeStore(seed: Data(#"{"token":"tok","email":"a@b.ru"}"#.utf8))
        #expect(store(fake).read() == nil)
    }

    @Test
    func write_replacesPreviousItemEntirely() {
        let fake = FakeStore()
        let s = store(fake)
        s.write(StoredAdminSession(token: "old", email: "old@b.ru", expiresAt: "2026-01-01T00:00:00Z"))

        s.write(StoredAdminSession(token: "new", email: "new@b.ru", expiresAt: "2027-01-01T00:00:00Z"))

        #expect(s.read() == StoredAdminSession(
            token: "new", email: "new@b.ru", expiresAt: "2027-01-01T00:00:00Z"
        ))
    }
}
