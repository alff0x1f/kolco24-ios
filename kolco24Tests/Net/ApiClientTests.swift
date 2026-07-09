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

    // MARK: - Часть 2: эндпоинты и условные GET (Зеркало `ApiClientTest.kt` fetch-группа)
    //
    // login/logout/bindTag (типизированные POST-методы `ApiClientTest.kt`) — контракт загрузки,
    // этап 6; здесь не зеркалируются. Generic `post` — часть 1 выше.

    private let racesJson = """
        {
          "races": [
            {
              "id": 8,
              "name": "Кольцо24 2026",
              "slug": "kolco24-2026",
              "date": "2026-06-20",
              "date_end": "2026-06-21",
              "place": "Сосновый бор",
              "reg_status": "open",
              "is_legend_visible": true
            }
          ]
        }
        """

    // MARK: fetchRaces

    @Test func fetchRaces_success_returnsRacesAndEtag_andSendsSignedRequest() async {
        // Зеркало `success_returnsRacesAndEtag_andSendsAllSignatureHeaders` (result+path часть;
        // заголовки покрыты в части 1).
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, headers: ["ETag": #""a1b2c3d4e5f6a7b8""#], bodyString: racesJson)
        let client = fixedTsClient(transport: transport)

        let result = await client.fetchRaces(etag: #""old-etag""#)

        guard case .success(let races, let etag) = result else {
            Issue.record("ожидался .success, получено \(result)"); return
        }
        #expect(races.count == 1)
        #expect(races[0].id == 8)
        #expect(races[0].name == "Кольцо24 2026")
        #expect(etag == #""a1b2c3d4e5f6a7b8""#)

        let recorded = transport.last!
        #expect(recorded.httpMethod == "GET")
        #expect(fullPath(recorded.url!) == "/app/races/")
        #expect(recorded.value(forHTTPHeaderField: "If-None-Match") == #""old-etag""#)
    }

    @Test func fetchRaces_pathIsRacesWithTrailingSlash_andSignatureMatches() async {
        // Зеркало `request_pathIsRacesWithTrailingSlash_andSignatureMatches`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, bodyString: racesJson)
        let client = fixedTsClient(transport: transport)

        _ = await client.fetchRaces(etag: nil)

        let recorded = transport.last!
        #expect(fullPath(recorded.url!) == "/app/races/")
        let sentTs = recorded.value(forHTTPHeaderField: "X-App-Ts")!
        let expectedSig = sign(
            secret: secret,
            canonical: buildCanonical(
                method: "GET", fullPath: "/app/races/", ts: sentTs, bodyHash: EMPTY_BODY_SHA256
            )
        )
        #expect(recorded.value(forHTTPHeaderField: "X-App-Sig") == expectedSig)
        #expect(recorded.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func fetchRaces_notModified_returnsNotModified() async {
        // Зеркало `notModified_returnsNotModified`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 304)
        let client = fixedTsClient(transport: transport)
        let result = await client.fetchRaces(etag: #""e""#)
        if case .notModified = result {} else { Issue.record("ожидался .notModified, получено \(result)") }
    }

    @Test func fetchRaces_forbidden_returnsForbidden() async {
        // Зеркало `forbidden_returnsForbidden`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 403, bodyString: #"{"detail":"Forbidden"}"#)
        let client = fixedTsClient(transport: transport)
        let result = await client.fetchRaces(etag: nil)
        if case .forbidden = result {} else { Issue.record("ожидался .forbidden, получено \(result)") }
    }

    @Test func fetchRaces_serverError_returnsErrorWithCode() async {
        // Зеркало `serverError_returnsErrorWithCode`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 500)
        let client = fixedTsClient(transport: transport)
        let result = await client.fetchRaces(etag: nil)
        if case .error(let code) = result { #expect(code == 500) }
        else { Issue.record("ожидался .error(500), получено \(result)") }
    }

    @Test func fetchRaces_connectionDrop_returnsErrorWithNullCode() async {
        // Зеркало `connectionDrop_returnsErrorWithNullCode`: URLError → .error(nil).
        let transport = FakeTransport()
        transport.enqueueError(URLError(.networkConnectionLost))
        let client = fixedTsClient(transport: transport)
        let result = await client.fetchRaces(etag: nil)
        if case .error(let code) = result { #expect(code == nil) }
        else { Issue.record("ожидался .error(nil), получено \(result)") }
    }

    @Test func fetchRaces_invalidJson_returnsError() async {
        // Зеркало `invalidJson_returnsError`: битый JSON → .error(nil).
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, bodyString: "{ not json")
        let client = fixedTsClient(transport: transport)
        let result = await client.fetchRaces(etag: nil)
        if case .error(let code) = result { #expect(code == nil) }
        else { Issue.record("ожидался .error, получено \(result)") }
    }

    // MARK: fetchTeams

    private let teamsJson = """
        {
          "race": 8,
          "categories": [
            { "id": 1, "code": "M", "short_name": "Муж", "name": "Мужская", "order": 1 }
          ],
          "teams": [
            {
              "id": 42,
              "teamname": "Лоси",
              "start_number": "201",
              "category2": 1,
              "ucount": 2,
              "paid_people": 2.0,
              "start_time": 1718200000,
              "finish_time": 0,
              "members": [
                { "name": "Иван", "number_in_team": 1 }
              ]
            }
          ]
        }
        """

    @Test func fetchTeams_success_returnsParsedBodyAndEtag() async {
        // Зеркало `fetchTeams_success_returnsParsedBodyAndEtag`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, headers: ["ETag": #""teams-v1""#], bodyString: teamsJson)
        let client = fixedTsClient(transport: transport)

        let result = await client.fetchTeams(raceId: 8, etag: #""old""#)

        guard case .success(let data, let etag) = result else {
            Issue.record("ожидался .success, получено \(result)"); return
        }
        #expect(data.race == 8)
        #expect(data.categories.count == 1)
        #expect(data.teams.count == 1)
        #expect(data.teams[0].teamname == "Лоси")
        #expect(data.teams[0].startNumber == "201")
        #expect(etag == #""teams-v1""#)

        let recorded = transport.last!
        #expect(fullPath(recorded.url!) == "/app/race/8/teams/")
        #expect(recorded.value(forHTTPHeaderField: "If-None-Match") == #""old""#)
    }

    @Test func fetchTeams_notModified_returnsNotModified() async {
        // Зеркало `fetchTeams_notModified_returnsNotModified`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 304)
        let client = fixedTsClient(transport: transport)
        let result = await client.fetchTeams(raceId: 8, etag: #""e""#)
        if case .notModified = result {} else { Issue.record("ожидался .notModified, получено \(result)") }
    }

    @Test func fetchTeams_forbidden_returnsForbidden() async {
        // Зеркало `fetchTeams_forbidden_returnsForbidden`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 403)
        let client = fixedTsClient(transport: transport)
        let result = await client.fetchTeams(raceId: 8, etag: nil)
        if case .forbidden = result {} else { Issue.record("ожидался .forbidden, получено \(result)") }
    }

    @Test func fetchTeams_serverError_returnsErrorWithCode() async {
        // Зеркало `fetchTeams_serverError_returnsErrorWithCode`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 500)
        let client = fixedTsClient(transport: transport)
        let result = await client.fetchTeams(raceId: 8, etag: nil)
        if case .error(let code) = result { #expect(code == 500) }
        else { Issue.record("ожидался .error(500), получено \(result)") }
    }

    @Test func fetchTeams_connectionDrop_returnsErrorWithNullCode() async {
        // Зеркало `fetchTeams_connectionDrop_returnsErrorWithNullCode`.
        let transport = FakeTransport()
        transport.enqueueError(URLError(.networkConnectionLost))
        let client = fixedTsClient(transport: transport)
        let result = await client.fetchTeams(raceId: 8, etag: nil)
        if case .error(let code) = result { #expect(code == nil) }
        else { Issue.record("ожидался .error(nil), получено \(result)") }
    }

    @Test func fetchTeams_invalidJson_returnsError() async {
        // Зеркало `fetchTeams_invalidJson_returnsError`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, bodyString: "{ not json")
        let client = fixedTsClient(transport: transport)
        let result = await client.fetchTeams(raceId: 8, etag: nil)
        if case .error(let code) = result { #expect(code == nil) }
        else { Issue.record("ожидался .error, получено \(result)") }
    }

    // MARK: fetchLegend

    private let legendJson = """
        {
          "race": 8,
          "checkpoints": [
            {
              "id": 101,
              "number": 5,
              "cost": 10,
              "type": "kp",
              "description": "У пня"
            }
          ]
        }
        """

    @Test func fetchLegend_success_returnsParsedBodyAndEtag() async {
        // Зеркало `fetchLegend_success_returnsParsedBodyAndEtag`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, headers: ["ETag": #""legend-v1""#], bodyString: legendJson)
        let client = fixedTsClient(transport: transport)

        let result = await client.fetchLegend(raceId: 8, etag: #""old""#)

        guard case .success(let data, let etag) = result else {
            Issue.record("ожидался .success, получено \(result)"); return
        }
        #expect(data.race == 8)
        #expect(data.checkpoints.count == 1)
        #expect(data.checkpoints[0].id == 101)
        #expect(data.checkpoints[0].number == 5)
        #expect(data.checkpoints[0].cost == 10)
        #expect(data.checkpoints[0].type == "kp")
        #expect(data.checkpoints[0].description == "У пня")
        #expect(etag == #""legend-v1""#)

        let recorded = transport.last!
        #expect(fullPath(recorded.url!) == "/app/race/8/legend/")
        #expect(recorded.value(forHTTPHeaderField: "If-None-Match") == #""old""#)
    }

    @Test func fetchLegend_emptyCheckpoints_returnsSuccessWithEmptyList() async {
        // Зеркало `fetchLegend_emptyCheckpoints_returnsSuccessWithEmptyList`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, bodyString: #"{"race":8,"checkpoints":[]}"#)
        let client = fixedTsClient(transport: transport)

        let result = await client.fetchLegend(raceId: 8, etag: nil)
        guard case .success(let data, _) = result else {
            Issue.record("ожидался .success, получено \(result)"); return
        }
        #expect(data.race == 8)
        #expect(data.checkpoints.isEmpty)
    }

    @Test func fetchLegend_notModified_returnsNotModified() async {
        // Зеркало `fetchLegend_notModified_returnsNotModified`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 304)
        let client = fixedTsClient(transport: transport)
        let result = await client.fetchLegend(raceId: 8, etag: #""e""#)
        if case .notModified = result {} else { Issue.record("ожидался .notModified, получено \(result)") }
    }

    @Test func fetchLegend_forbidden_returnsForbidden() async {
        // Зеркало `fetchLegend_forbidden_returnsForbidden`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 403)
        let client = fixedTsClient(transport: transport)
        let result = await client.fetchLegend(raceId: 8, etag: nil)
        if case .forbidden = result {} else { Issue.record("ожидался .forbidden, получено \(result)") }
    }

    @Test func fetchLegend_serverError_returnsErrorWithCode() async {
        // Зеркало `fetchLegend_serverError_returnsErrorWithCode`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 500)
        let client = fixedTsClient(transport: transport)
        let result = await client.fetchLegend(raceId: 8, etag: nil)
        if case .error(let code) = result { #expect(code == 500) }
        else { Issue.record("ожидался .error(500), получено \(result)") }
    }

    @Test func fetchLegend_connectionDrop_returnsErrorWithNullCode() async {
        // Зеркало `fetchLegend_connectionDrop_returnsErrorWithNullCode`.
        let transport = FakeTransport()
        transport.enqueueError(URLError(.networkConnectionLost))
        let client = fixedTsClient(transport: transport)
        let result = await client.fetchLegend(raceId: 8, etag: nil)
        if case .error(let code) = result { #expect(code == nil) }
        else { Issue.record("ожидался .error(nil), получено \(result)") }
    }

    // MARK: fetchMemberTags

    private let memberTagsJson = """
        {
          "member_tags": [
            {"number": 101, "nfc_uid": "04A2B3C4D5E680"},
            {"number": 102, "nfc_uid": "0489AB12CD34EF"}
          ]
        }
        """

    @Test func fetchMemberTags_success_returnsParsedBodyAndEtag() async {
        // Зеркало `fetchMemberTags_success_returnsParsedBodyAndEtag`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, headers: ["ETag": #""tags-v1""#], bodyString: memberTagsJson)
        let client = fixedTsClient(transport: transport)

        let result = await client.fetchMemberTags(raceId: 8, etag: #""old""#)

        guard case .success(let data, let etag) = result else {
            Issue.record("ожидался .success, получено \(result)"); return
        }
        #expect(data.memberTags.count == 2)
        #expect(data.memberTags[0].number == 101)
        #expect(data.memberTags[0].nfcUid == "04A2B3C4D5E680")
        #expect(etag == #""tags-v1""#)

        let recorded = transport.last!
        #expect(fullPath(recorded.url!) == "/app/race/8/member_tags/")
        #expect(recorded.value(forHTTPHeaderField: "If-None-Match") == #""old""#)
    }

    @Test func fetchMemberTags_notModified_returnsNotModified() async {
        // Зеркало `fetchMemberTags_notModified_returnsNotModified`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 304)
        let client = fixedTsClient(transport: transport)
        let result = await client.fetchMemberTags(raceId: 8, etag: #""e""#)
        if case .notModified = result {} else { Issue.record("ожидался .notModified, получено \(result)") }
    }

    @Test func fetchMemberTags_forbidden_returnsForbidden() async {
        // Зеркало `fetchMemberTags_forbidden_returnsForbidden`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 403)
        let client = fixedTsClient(transport: transport)
        let result = await client.fetchMemberTags(raceId: 8, etag: nil)
        if case .forbidden = result {} else { Issue.record("ожидался .forbidden, получено \(result)") }
    }

    @Test func fetchMemberTags_serverError_returnsErrorWithCode() async {
        // Зеркало `fetchMemberTags_serverError_returnsErrorWithCode`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 500)
        let client = fixedTsClient(transport: transport)
        let result = await client.fetchMemberTags(raceId: 8, etag: nil)
        if case .error(let code) = result { #expect(code == 500) }
        else { Issue.record("ожидался .error(500), получено \(result)") }
    }

    @Test func fetchMemberTags_connectionDrop_returnsErrorWithNullCode() async {
        // Зеркало `fetchMemberTags_connectionDrop_returnsErrorWithNullCode`.
        let transport = FakeTransport()
        transport.enqueueError(URLError(.networkConnectionLost))
        let client = fixedTsClient(transport: transport)
        let result = await client.fetchMemberTags(raceId: 8, etag: nil)
        if case .error(let code) = result { #expect(code == nil) }
        else { Issue.record("ожидался .error(nil), получено \(result)") }
    }

    @Test func fetchMemberTags_invalidJson_returnsError() async {
        // Зеркало `fetchMemberTags_invalidJson_returnsError`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, bodyString: "{ not json")
        let client = fixedTsClient(transport: transport)
        let result = await client.fetchMemberTags(raceId: 8, etag: nil)
        if case .error(let code) = result { #expect(code == nil) }
        else { Issue.record("ожидался .error, получено \(result)") }
    }

    // MARK: fetchSync (без ETag)

    @Test func fetchSync_fullManifest_parsesBothLeaseFields() async {
        // Зеркало `fetchSync_fullManifest_parsesBothLeaseFields`.
        let transport = FakeTransport()
        transport.enqueue(
            statusCode: 200,
            bodyString: #"{"race":8,"data_source":"local","lease_ttl_seconds":43200,"lease_expires_at":1718300000}"#
        )
        let client = fixedTsClient(transport: transport)

        let result = await client.fetchSync(raceId: 8)
        guard case .success(let data, let etag) = result else {
            Issue.record("ожидался .success, получено \(result)"); return
        }
        #expect(data.race == 8)
        #expect(data.dataSource == "local")
        #expect(data.leaseTtlSeconds == 43200)
        #expect(data.leaseExpiresAt == 1718300000)
        #expect(etag == nil)

        let recorded = transport.last!
        #expect(fullPath(recorded.url!) == "/app/race/8/sync/")
        #expect(recorded.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func fetchSync_stubbedManifest_bothLeaseFieldsNull() async {
        // Зеркало `fetchSync_stubbedManifest_bothLeaseFieldsNull`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200, bodyString: #"{"race":8,"data_source":"cloud"}"#)
        let client = fixedTsClient(transport: transport)

        let result = await client.fetchSync(raceId: 8)
        guard case .success(let data, _) = result else {
            Issue.record("ожидался .success, получено \(result)"); return
        }
        #expect(data.dataSource == "cloud")
        #expect(data.leaseTtlSeconds == nil)
        #expect(data.leaseExpiresAt == nil)
    }

    @Test func fetchSync_unknownVersionsKey_isIgnored() async {
        // Зеркало `fetchSync_unknownVersionsKey_isIgnored`.
        let transport = FakeTransport()
        transport.enqueue(
            statusCode: 200,
            bodyString: #"{"race":8,"data_source":"local","versions":{"teams":"abc123","legend":"def456"}}"#
        )
        let client = fixedTsClient(transport: transport)

        let result = await client.fetchSync(raceId: 8)
        guard case .success(let data, _) = result else {
            Issue.record("ожидался .success, получено \(result)"); return
        }
        #expect(data.dataSource == "local")
    }

    @Test func fetchSync_404_returnsErrorWith404() async {
        // Зеркало `fetchSync_404_returnsErrorWith404`.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 404)
        let client = fixedTsClient(transport: transport)
        let result = await client.fetchSync(raceId: 999)
        if case .error(let code) = result { #expect(code == 404) }
        else { Issue.record("ожидался .error(404), получено \(result)") }
    }

    @Test func fetchSync_connectionDrop_returnsErrorWithNullCode() async {
        // Зеркало `fetchSync_connectionDrop_returnsErrorWithNullCode`.
        let transport = FakeTransport()
        transport.enqueueError(URLError(.networkConnectionLost))
        let client = fixedTsClient(transport: transport)
        let result = await client.fetchSync(raceId: 8)
        if case .error(let code) = result { #expect(code == nil) }
        else { Issue.record("ожидался .error(nil), получено \(result)") }
    }

    // MARK: - БОНУС-тесты

    @Test func conditionalGet_parserNotInvokedOnNon200() async {
        // Свыше Kotlin: явно фиксируем «parse не вызывается на не-200» для условного GET (у Kotlin
        // это только у POST; для GET доказывается тем, что ветки 304/403/500 не парсят тело).
        let transport = FakeTransport()
        transport.enqueue(statusCode: 304, bodyString: "{ not json")
        let client = fixedTsClient(transport: transport)

        let result: FetchResult<String> = await client.conditionalGet(
            url: url("/app/races/"), etag: #""e""#
        ) { _ in
            Issue.record("parse не должен вызываться на не-200 ветке")
            return ""
        }
        if case .notModified = result {} else { Issue.record("ожидался .notModified, получено \(result)") }
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
