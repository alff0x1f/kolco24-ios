//
//  SigningTests.swift
//  kolco24Tests
//
//  Зеркало 7 «чистых» кейсов из `data/api/SigningTest.kt` 1:1. Остальные 9
//  `interceptor_*`-кейсов тестируют OkHttp-`Interceptor` → этап 3 (URLSession-аналог).
//

import Foundation
import Testing
@testable import kolco24

struct SigningTests {

    @Test func buildCanonical_matchesApiDocExample() {
        let canonical = buildCanonical(
            method: "GET",
            fullPath: "/app/race/8/teams/",
            ts: "1718200000",
            bodyHash: EMPTY_BODY_SHA256
        )

        let expected = [
            "GET",
            "/app/race/8/teams/",
            "1718200000",
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        ].joined(separator: "\n")
        #expect(canonical == expected)
    }

    @Test func buildCanonical_uppercasesMethod() {
        let canonical = buildCanonical(
            method: "get",
            fullPath: "/app/races/",
            ts: "1718200000",
            bodyHash: EMPTY_BODY_SHA256
        )

        #expect(canonical.split(separator: "\n", maxSplits: 1)[0] == "GET")
    }

    @Test func sign_matchesExternallyComputedVector() {
        // Вектор посчитан Python-ским hmac: secret="test-secret-123" над каноническим
        // примером из API.md. Проверка:
        //   python3 -c 'import hmac,hashlib;print(hmac.new(b"test-secret-123",
        //   b"GET\n/app/race/8/teams/\n1718200000\n"
        //   b"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        //   hashlib.sha256).hexdigest())'
        let canonical = buildCanonical(
            method: "GET",
            fullPath: "/app/race/8/teams/",
            ts: "1718200000",
            bodyHash: EMPTY_BODY_SHA256
        )

        let sig = sign(secret: "test-secret-123", canonical: canonical)

        #expect(sig == "cf1c254fb2eac6c7efde1cff6efe9553878370299cd60a42be4d2105a8072588")
    }

    @Test func sign_producesLowerCaseHex64Chars() {
        let sig = sign(
            secret: "secret",
            canonical: buildCanonical(method: "GET", fullPath: "/app/races/", ts: "1", bodyHash: EMPTY_BODY_SHA256)
        )

        #expect(sig.count == 64)
        #expect(sig.lowercased() == sig)
    }

    @Test func sha256Hex_emptyBytesMatchesConstant() {
        #expect(sha256Hex(Data()) == EMPTY_BODY_SHA256)
    }

    @Test func sha256Hex_knownVector() {
        // python3 -c 'import hashlib;print(hashlib.sha256(b"abc").hexdigest())'
        #expect(sha256Hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func postBody_canonicalPlacesBodyHashAsFourthPart() {
        let body = #"{"email":"a@b.c","password":"pw"}"#
        let computed = sha256Hex(Data(body.utf8))
        let canonical = buildCanonical(method: "POST", fullPath: "/app/login/", ts: "1718200000", bodyHash: computed)

        let parts = canonical.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(parts[0] == "POST")
        #expect(parts[1] == "/app/login/")
        #expect(parts[2] == "1718200000")
        // 4-я часть канонической строки — ровно хеш тела (не EMPTY_BODY_SHA256).
        #expect(parts[3] == computed)
    }
}
