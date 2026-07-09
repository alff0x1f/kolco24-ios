//
//  ApiClientTests.swift
//  kolco24Tests
//
//  Часть 1: пайплайн (подпись, серверное время, 403-retry, generic post).
//  Зеркало `data/api/ApiClientTest.kt` (POST-группа + проверки заголовков) и retry/подпись-матрицы
//  из `data/api/SigningTest.kt` `interceptor_*`-кейсов (в этапе 1 пропущены — retry жил в
//  OkHttp-интерсепторе, теперь он в пайплайне `ApiClient.send`). Эндпоинты и условные GET
//  (`fetchRaces` и т.д.) — часть 2, задача 4.
//
//  Подпись сверяется независимым пересчётом теми же `Core/Api`-функциями (`buildCanonical`/`sign`)
//  над перехваченным `URLRequest` — как в `SigningTest.kt`.
//

import Foundation
import Testing
@testable import kolco24

struct ApiClientTests {

    private let keyId = "ios-v1"
    private let secret = "test-secret-123"
    private let installId = "install-abc"
    private let appVersion = "2.0.1"
    private let ts: Int64 = 1_718_200_000

    // MARK: - Фикстуры

    /// Собирает `ApiClient` над фейк-транспортом с фиксированным `ts` по умолчанию.
    private func makeClient(
        transport: FakeTransport,
        nowSeconds: @escaping () async -> Int64,
        onServerTime: ((ServerTimeSample) async -> Void)? = nil,
        tokenProvider: @escaping () -> String? = { nil },
        elapsedNowMs: @escaping () -> Int64 = { 0 }
    ) -> ApiClient {
        ApiClient(
            baseURL: "https://example.test",
            keyId: keyId,
            secret: secret,
            installId: installId,
            appVersion: appVersion,
            nowSeconds: nowSeconds,
            elapsedNowMs: elapsedNowMs,
            onServerTime: onServerTime,
            tokenProvider: tokenProvider,
            transport: transport.handle
        )
    }

    private func fixedTsClient(
        transport: FakeTransport,
        onServerTime: ((ServerTimeSample) async -> Void)? = nil,
        tokenProvider: @escaping () -> String? = { nil }
    ) -> ApiClient {
        makeClient(
            transport: transport,
            nowSeconds: { self.ts },
            onServerTime: onServerTime,
            tokenProvider: tokenProvider
        )
    }

    /// Пересчёт `fullPath` (encodedPath + `?query`) — тот же вид, что подписывает клиент.
    private func fullPath(_ url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var path = components.percentEncodedPath
        if let query = components.percentEncodedQuery { path += "?" + query }
        return path
    }

    private func url(_ path: String) -> URL { URL(string: "https://example.test\(path)")! }

    // MARK: - Заголовки подписи на GET

    @Test func get_sendsAllSixSignatureHeaders() async throws {
        // Зеркало `success_returnsRacesAndEtag_andSendsAllSignatureHeaders` (заголовочная часть).
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, bodyString: "{}")
        let client = fixedTsClient(transport: transport)

        _ = try await client.send(
            method: "GET", url: url("/app/races/"), body: nil, contentType: nil,
            ifNoneMatch: #""old-etag""#
        )

        let recorded = try #require(transport.last)
        #expect(recorded.value(forHTTPHeaderField: "X-App-Key-Id") == keyId)
        #expect(recorded.value(forHTTPHeaderField: "X-App-Sig") != nil)
        #expect(recorded.value(forHTTPHeaderField: "X-App-Ts") == String(ts))
        #expect(recorded.value(forHTTPHeaderField: "X-Install-Id") == installId)
        #expect(recorded.value(forHTTPHeaderField: "X-App-Platform") == "ios")
        #expect(recorded.value(forHTTPHeaderField: "X-App-Version") == appVersion)
        // If-None-Match echoed verbatim, с кавычками.
        #expect(recorded.value(forHTTPHeaderField: "If-None-Match") == #""old-etag""#)
    }

    @Test func get_signatureMatchesRecomputed_andEmptyBodyHash_andNoIfNoneMatch() async throws {
        // Зеркало `request_pathIsRacesWithTrailingSlash_andSignatureMatches`
        // + `interceptor_emptyGetBodyUsesEmptyBodyHash`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, bodyString: "{}")
        let client = fixedTsClient(transport: transport)

        _ = try await client.send(
            method: "GET", url: url("/app/races/"), body: nil, contentType: nil, ifNoneMatch: nil
        )

        let recorded = try #require(transport.last)
        #expect(fullPath(recorded.url!) == "/app/races/")
        let sentTs = try #require(recorded.value(forHTTPHeaderField: "X-App-Ts"))
        let expectedSig = sign(
            secret: secret,
            canonical: buildCanonical(
                method: "GET", fullPath: "/app/races/", ts: sentTs, bodyHash: EMPTY_BODY_SHA256
            )
        )
        #expect(recorded.value(forHTTPHeaderField: "X-App-Sig") == expectedSig)
        #expect(recorded.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    // MARK: - Bearer

    @Test func addsBearerWhenTokenProviderNonNull() async throws {
        // Зеркало `interceptor_addsBearerWhenTokenProviderNonNull`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, bodyString: "{}")
        let client = fixedTsClient(transport: transport, tokenProvider: { "tok-123" })

        _ = try await client.send(
            method: "GET", url: url("/app/races/"), body: nil, contentType: nil, ifNoneMatch: nil
        )

        #expect(transport.last?.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
    }

    @Test func noBearerWhenTokenNull() async throws {
        // Зеркало `interceptor_noBearerWhenTokenNull`. Bearer НЕ входит в канонику — подпись та же.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, bodyString: "{}")
        let client = fixedTsClient(transport: transport, tokenProvider: { nil })

        _ = try await client.send(
            method: "GET", url: url("/app/races/"), body: nil, contentType: nil, ifNoneMatch: nil
        )

        #expect(transport.last?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: - Хэш тела POST (байт-в-байт)

    @Test func post_bodyHashSignsBodyBytes() async {
        // Зеркало `interceptor_postBodyHashSignsBodyBytes`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, bodyString: "{}")
        let client = fixedTsClient(transport: transport)
        let body = Data(#"{"k":"v"}"#.utf8)

        _ = await client.post(url: url("/app/login/"), body: body) { $0 }

        let recorded = transport.last!
        let sentTs = recorded.value(forHTTPHeaderField: "X-App-Ts")!
        let expected = sign(
            secret: secret,
            canonical: buildCanonical(
                method: "POST", fullPath: "/app/login/", ts: sentTs, bodyHash: sha256Hex(body)
            )
        )
        #expect(recorded.value(forHTTPHeaderField: "X-App-Sig") == expected)
        // Ровно эти байты и отправлены.
        #expect(recorded.httpBody == body)
    }

    @Test func post_binaryBodyHashSignsRawBytes() async {
        // Зеркало `interceptor_binaryPostBodyHashSignsRawBytes` — сырые JPEG-байты (0xFF-старший).
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, bodyString: "")
        let client = fixedTsClient(transport: transport)
        let jpeg = Data([0xFF, 0xD8, 1, 2, 3])

        _ = await client.post(
            url: url("/app/race/8/mark/mark-1/photo/frame-uuid"),
            body: jpeg,
            contentType: "image/jpeg"
        ) { $0 }

        let recorded = transport.last!
        let sentTs = recorded.value(forHTTPHeaderField: "X-App-Ts")!
        let expected = sign(
            secret: secret,
            canonical: buildCanonical(
                method: "POST",
                fullPath: "/app/race/8/mark/mark-1/photo/frame-uuid",
                ts: sentTs,
                bodyHash: sha256Hex(jpeg)
            )
        )
        #expect(recorded.value(forHTTPHeaderField: "X-App-Sig") == expected)
        #expect(recorded.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
    }

    // MARK: - 403-retry матрица (Зеркало `SigningTest.kt` `interceptor_*`)

    @Test func retriesGetOnceOn403WhenTsChanged() async throws {
        // Зеркало `interceptor_retriesGetOnceOn403WhenTsChanged`: ts 100→200, коды 403→200.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 403)
        transport.enqueue(statusCode: 200, bodyString: "{}")
        let tsSeq = TsSequence([100, 200])
        let client = makeClient(transport: transport, nowSeconds: { tsSeq.next() })

        let (_, response) = try await client.send(
            method: "GET", url: url("/app/races/"), body: nil, contentType: nil, ifNoneMatch: nil
        )

        #expect(transport.callCount == 2)
        // Retry переподписался свежим ts=200.
        #expect(transport.recorded.last?.value(forHTTPHeaderField: "X-App-Ts") == "200")
        #expect(response.statusCode == 200)
    }

    @Test func doesNotRetryGetWhenTsUnchanged() async throws {
        // Зеркало `interceptor_doesNotRetryGetWhenTsUnchanged`: ts константа, код 403.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 403)
        let client = makeClient(transport: transport, nowSeconds: { 100 })

        let (_, response) = try await client.send(
            method: "GET", url: url("/app/races/"), body: nil, contentType: nil, ifNoneMatch: nil
        )

        #expect(transport.callCount == 1)
        #expect(response.statusCode == 403)
    }

    @Test func doesNotRetryPostEvenWhenTsChangedAnd403() async {
        // Зеркало `interceptor_doesNotRetryPostEvenWhenTsChangedAnd403`: ts 100→200, код 403, POST.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 403)
        let tsSeq = TsSequence([100, 200])
        let client = makeClient(transport: transport, nowSeconds: { tsSeq.next() })

        let result = await client.post(url: url("/app/login/"), body: Data(#"{"k":"v"}"#.utf8)) { $0 }

        #expect(transport.callCount == 1)
        if case .forbidden = result {} else { Issue.record("ожидался .forbidden, получено \(result)") }
    }

    @Test func doesNotRetryGetOn200() async throws {
        // Зеркало `interceptor_doesNotRetryGetOn200`: ts 100→200, код 200 — retry не при чём.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, bodyString: "{}")
        let tsSeq = TsSequence([100, 200])
        let client = makeClient(transport: transport, nowSeconds: { tsSeq.next() })

        let (_, response) = try await client.send(
            method: "GET", url: url("/app/races/"), body: nil, contentType: nil, ifNoneMatch: nil
        )

        #expect(transport.callCount == 1)
        #expect(response.statusCode == 200)
    }

    // MARK: - onServerTime (перезаякоривание, вкл. на 403; nil у LAN)

    private let liveDateHeader = "Thu, 01 Jan 1970 00:00:10 GMT" // 10_000 мс, tz-free

    @Test func onServerTime_calledOn200() async throws {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, headers: ["Date": liveDateHeader], bodyString: "{}")
        let recorder = SampleRecorder()
        let client = fixedTsClient(transport: transport, onServerTime: { recorder.record($0) })

        _ = try await client.send(
            method: "GET", url: url("/app/races/"), body: nil, contentType: nil, ifNoneMatch: nil
        )

        #expect(recorder.samples.count == 1)
        #expect(recorder.samples.first?.serverEpochMs == 10_000)
    }

    @Test func onServerTime_calledOn403() async throws {
        // Ключ самолечения: якорь обновляется даже на 403 (Date живой). Фикс. ts → без retry, 1 сэмпл.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 403, headers: ["Date": liveDateHeader])
        let recorder = SampleRecorder()
        let client = fixedTsClient(transport: transport, onServerTime: { recorder.record($0) })

        let (_, response) = try await client.send(
            method: "GET", url: url("/app/races/"), body: nil, contentType: nil, ifNoneMatch: nil
        )

        #expect(response.statusCode == 403)
        #expect(recorder.samples.count == 1)
    }

    @Test func onServerTime_nilClient_notInvoked() async throws {
        // LAN-клиент: `onServerTime = nil` — сэмпл никуда не уходит, пайплайн работает как обычно.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, headers: ["Date": liveDateHeader], bodyString: "{}")
        let client = fixedTsClient(transport: transport, onServerTime: nil)

        let (_, response) = try await client.send(
            method: "GET", url: url("/app/races/"), body: nil, contentType: nil, ifNoneMatch: nil
        )

        #expect(response.statusCode == 200)
    }

    // MARK: - Generic POST: маппинг статусов (Зеркало `ApiClientTest.kt` POST-группа)

    @Test func post_200_parsesBodyIntoSuccess_andSendsJsonBody() async {
        // Зеркало `post_200_parsesBodyIntoSuccess_andSendsJsonBody`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, bodyString: #"{"v":7}"#)
        let client = fixedTsClient(transport: transport)

        let result = await client.post(url: url("/app/x/"), body: Data(#"{"a":1}"#.utf8)) {
            String(data: $0, encoding: .utf8)!
        }

        if case .success(let s) = result { #expect(s == #"{"v":7}"#) }
        else { Issue.record("ожидался .success, получено \(result)") }

        let recorded = transport.last!
        #expect(recorded.httpMethod == "POST")
        #expect(fullPath(recorded.url!) == "/app/x/")
        #expect(recorded.httpBody == Data(#"{"a":1}"#.utf8))
        #expect(recorded.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func post_201_parsesBodyIntoSuccess() async {
        // Зеркало `post_201_parsesBodyIntoSuccess`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 201, bodyString: "ok")
        let client = fixedTsClient(transport: transport)

        let result = await client.post(url: url("/app/x/"), body: Data()) {
            String(data: $0, encoding: .utf8)!
        }
        if case .success(let s) = result { #expect(s == "ok") }
        else { Issue.record("ожидался .success, получено \(result)") }
    }

    @Test func post_emptyBody_doesNotInvokeParseOnError() async {
        // Зеркало `post_emptyBody_doesNotInvokeParseOnError`: 401 без тела не должен дойти до парсера.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 401)
        let client = fixedTsClient(transport: transport)

        let result: PostResult<String> = await client.post(url: url("/app/x/"), body: Data()) { _ in
            Issue.record("парсер не должен вызываться на ветке ошибки")
            return ""
        }
        if case .unauthorized = result {} else { Issue.record("ожидался .unauthorized, получено \(result)") }
    }

    @Test func post_400_returnsBadRequest() async {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 400, bodyString: #"{"detail":"bad"}"#)
        let client = fixedTsClient(transport: transport)
        let result = await client.post(url: url("/app/x/"), body: Data()) { $0 }
        if case .badRequest = result {} else { Issue.record("ожидался .badRequest, получено \(result)") }
    }

    @Test func post_403_returnsForbidden() async {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 403)
        let client = fixedTsClient(transport: transport)
        let result = await client.post(url: url("/app/x/"), body: Data()) { $0 }
        if case .forbidden = result {} else { Issue.record("ожидался .forbidden, получено \(result)") }
    }

    @Test func post_409_returnsConflict() async {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 409)
        let client = fixedTsClient(transport: transport)
        let result = await client.post(url: url("/app/x/"), body: Data()) { $0 }
        if case .conflict = result {} else { Issue.record("ожидался .conflict, получено \(result)") }
    }

    @Test func post_429_returnsRateLimited() async {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 429)
        let client = fixedTsClient(transport: transport)
        let result = await client.post(url: url("/app/x/"), body: Data()) { $0 }
        if case .rateLimited = result {} else { Issue.record("ожидался .rateLimited, получено \(result)") }
    }

    @Test func post_500_returnsErrorWithCode() async {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 500)
        let client = fixedTsClient(transport: transport)
        let result = await client.post(url: url("/app/x/"), body: Data()) { $0 }
        if case .error(let code) = result { #expect(code == 500) }
        else { Issue.record("ожидался .error(500), получено \(result)") }
    }

    @Test func post_connectionDrop_returnsOffline() async {
        // Зеркало `post_connectionDrop_returnsOffline`: URLError → .offline.
        let transport = FakeTransport()
        transport.enqueueError(URLError(.networkConnectionLost))
        let client = fixedTsClient(transport: transport)
        let result = await client.post(url: url("/app/x/"), body: Data()) { $0 }
        if case .offline = result {} else { Issue.record("ожидался .offline, получено \(result)") }
    }

    @Test func post_parseThrows_returnsErrorWithNullCode() async {
        // Зеркало `post_parseThrowsSerialization_returnsErrorWithNullCode`: парс-ошибка → .error(nil).
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, bodyString: "{ not json")
        let client = fixedTsClient(transport: transport)
        let result: PostResult<String> = await client.post(url: url("/app/x/"), body: Data()) { _ in
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad json"))
        }
        if case .error(let code) = result { #expect(code == nil) }
        else { Issue.record("ожидался .error(nil), получено \(result)") }
    }
}

// MARK: - Хелперы

/// Последовательность `ts`-значений для retry-матрицы (аналог `Iterator<Long>` из `SigningTest.kt`);
/// после исчерпания клампится к последнему.
private final class TsSequence {
    private let values: [Int64]
    private var index = 0
    init(_ values: [Int64]) { self.values = values }
    func next() -> Int64 {
        defer { index += 1 }
        return values[Swift.min(index, values.count - 1)]
    }
}

/// Сборщик принятых `ServerTimeSample` (проверка вызовов `onServerTime`).
private final class SampleRecorder {
    private(set) var samples: [ServerTimeSample] = []
    func record(_ sample: ServerTimeSample) { samples.append(sample) }
}
