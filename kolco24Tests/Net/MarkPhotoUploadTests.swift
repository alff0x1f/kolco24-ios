//
//  MarkPhotoUploadTests.swift
//  kolco24Tests
//
//  Эндпоинт кадра `ApiClient.uploadMarkPhoto` через `FakeTransport`. Зеркало Kotlin
//  `uploadMarkPhoto` (ApiClient.kt L267–273): POST сырых JPEG-байт на
//  `/app/race/<raceId>/mark/<markId>/photo/<frameId>` (путь БЕЗ хвостового слэша),
//  `Content-Type: image/jpeg`, подпись по хэшу тех же байт, без ретраев, `200`/`201` → success.
//
//  Подпись сверяется независимым пересчётом теми же `Core/Api`-функциями над перехваченным
//  `URLRequest` (как в `ApiClientTests`).
//

import Foundation
import Testing
@testable import kolco24

struct MarkPhotoUploadTests {

    private let keyId = "ios-v1"
    private let secret = "test-secret-123"
    private let installId = "install-abc"
    private let appVersion = "2.0.1"
    private let ts: Int64 = 1_718_200_000

    private func makeClient(
        transport: FakeTransport,
        nowSeconds: @escaping () async -> Int64
    ) -> ApiClient {
        ApiClient(
            baseURL: "https://example.test",
            keyId: keyId,
            secret: secret,
            installId: installId,
            appVersion: appVersion,
            nowSeconds: nowSeconds,
            elapsedNowMs: { 0 },
            onServerTime: nil,
            tokenProvider: { nil },
            transport: transport.handle
        )
    }

    private func fixedTsClient(transport: FakeTransport) -> ApiClient {
        makeClient(transport: transport, nowSeconds: { self.ts })
    }

    private func fullPath(_ url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var path = components.percentEncodedPath
        if let query = components.percentEncodedQuery { path += "?" + query }
        return path
    }

    /// Сырые JPEG-байты со старшим 0xFF — проверяем, что байты не искажаются.
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 200, 255, 0])

    // MARK: - Метод / путь / Content-Type / тело-байты как есть

    @Test func uploadsRawJpegToNoTrailingSlashPath() async {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200)
        let client = fixedTsClient(transport: transport)

        _ = await client.uploadMarkPhoto(
            raceId: 8, markId: "mark-1", frameId: "frame-uuid", bytes: jpeg
        )

        let recorded = transport.last!
        #expect(recorded.httpMethod == "POST")
        // Путь БЕЗ завершающего слэша (1:1 с Kotlin).
        #expect(fullPath(recorded.url!) == "/app/race/8/mark/mark-1/photo/frame-uuid")
        #expect(recorded.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
        // Ровно эти байты и отправлены.
        #expect(recorded.httpBody == jpeg)
    }

    @Test func signsOverRawJpegBytes() async {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200)
        let client = fixedTsClient(transport: transport)

        _ = await client.uploadMarkPhoto(
            raceId: 8, markId: "mark-1", frameId: "frame-uuid", bytes: jpeg
        )

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
    }

    // MARK: - Маппинг статусов

    @Test func status200_returnsSuccess() async {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 200)
        let client = fixedTsClient(transport: transport)

        let result = await client.uploadMarkPhoto(
            raceId: 8, markId: "m", frameId: "f", bytes: jpeg
        )
        if case .success = result {} else { Issue.record("ожидался .success, получено \(result)") }
    }

    @Test func status201_returnsSuccess() async {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 201)
        let client = fixedTsClient(transport: transport)

        let result = await client.uploadMarkPhoto(
            raceId: 8, markId: "m", frameId: "f", bytes: jpeg
        )
        if case .success = result {} else { Issue.record("ожидался .success, получено \(result)") }
    }

    @Test func status403_forbidden_noRetry() async {
        // 403 не ретраится на POST (гарантия `post`) — ровно один запрос.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 403)
        // Меняющийся ts — если бы был ретрай (как на GET), он бы дёрнул транспорт второй раз.
        let counter = TsCounter()
        let client = makeClient(transport: transport, nowSeconds: { counter.next() })

        let result = await client.uploadMarkPhoto(
            raceId: 8, markId: "m", frameId: "f", bytes: jpeg
        )

        #expect(transport.callCount == 1)
        if case .forbidden = result {} else { Issue.record("ожидался .forbidden, получено \(result)") }
    }

    @Test func status413_returnsError413() async {
        // Payload Too Large — hard-кадр (ядовитый); дренаж переведёт кадр в pending и пропустит.
        let transport = FakeTransport()
        transport.enqueue(statusCode: 413)
        let client = fixedTsClient(transport: transport)

        let result = await client.uploadMarkPhoto(
            raceId: 8, markId: "m", frameId: "f", bytes: jpeg
        )
        if case .error(let code) = result { #expect(code == 413) }
        else { Issue.record("ожидался .error(413), получено \(result)") }
    }

    @Test func status400_returnsBadRequest() async {
        let transport = FakeTransport()
        transport.enqueue(statusCode: 400)
        let client = fixedTsClient(transport: transport)

        let result = await client.uploadMarkPhoto(
            raceId: 8, markId: "m", frameId: "f", bytes: jpeg
        )
        if case .badRequest = result {} else { Issue.record("ожидался .badRequest, получено \(result)") }
    }

    @Test func transportError_returnsOffline() async {
        // URLError на POST → .offline (ожидаемое состояние загрузки на гонке).
        let transport = FakeTransport()
        transport.enqueueError(URLError(.notConnectedToInternet))
        let client = fixedTsClient(transport: transport)

        let result = await client.uploadMarkPhoto(
            raceId: 8, markId: "m", frameId: "f", bytes: jpeg
        )
        if case .offline = result {} else { Issue.record("ожидался .offline, получено \(result)") }
    }
}

/// Отдаёт возрастающие ts (100, 200, …) для проверки отсутствия ретрая на POST.
private final class TsCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0
    func next() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        value += 100
        return value
    }
}
