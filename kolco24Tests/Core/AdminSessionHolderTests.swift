//
//  AdminSessionHolderTests.swift
//  kolco24Tests
//
//  Свежие тесты `AdminSessionHolder` (прямого Kotlin-зеркала нет): синхронный `token` при
//  loggedIn/loggedOut, публикация изменений в стрим, дедуп равных, seed первым кадром.
//

import Foundation
import Testing
@testable import kolco24

struct AdminSessionHolderTests {

    private let loggedIn = AdminSession.loggedIn(email: "a@b.ru", token: "tok-1", expiresAt: "2099-01-01T00:00:00Z")
    private let loggedIn2 = AdminSession.loggedIn(email: "c@d.ru", token: "tok-2", expiresAt: "2099-01-01T00:00:00Z")

    // MARK: token / session

    @Test
    func token_isNil_whenLoggedOut() {
        let holder = AdminSessionHolder(initial: .loggedOut)
        #expect(holder.token == nil)
        #expect(holder.session == .loggedOut)
    }

    @Test
    func token_returnsToken_whenLoggedIn() {
        let holder = AdminSessionHolder(initial: loggedIn)
        #expect(holder.token == "tok-1")
        #expect(holder.session == loggedIn)
    }

    @Test
    func set_updatesSessionAndToken() {
        let holder = AdminSessionHolder(initial: .loggedOut)
        holder.set(loggedIn)
        #expect(holder.token == "tok-1")

        holder.set(.loggedOut)
        #expect(holder.token == nil)
    }

    // MARK: stream

    @Test
    func stream_publishesInitialThenChanges() async {
        let holder = AdminSessionHolder(initial: .loggedOut)
        var iter = holder.updates.makeAsyncIterator()

        let first = await iter.next()
        #expect((first ?? nil) == .loggedOut)

        holder.set(loggedIn)
        let second = await iter.next()
        #expect((second ?? nil) == loggedIn)
    }

    @Test
    func stream_dedupsEqual() async {
        let holder = AdminSessionHolder(initial: loggedIn)
        var iter = holder.updates.makeAsyncIterator()

        _ = await iter.next() // засеянный loggedIn

        holder.set(loggedIn)   // дедуп — не публикуется
        holder.set(loggedIn2)  // публикуется

        let next = await iter.next()
        #expect((next ?? nil) == loggedIn2)
    }
}
