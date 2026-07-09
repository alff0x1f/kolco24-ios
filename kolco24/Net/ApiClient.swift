//
//  ApiClient.swift
//  kolco24
//
//  Порт `data/api/ApiClient.kt` + `data/api/AppSignatureInterceptor.kt` + `data/api/ServerTimeInterceptor.kt`.
//
//  Адаптация под платформу (требование этапа: НЕ 1в1 из Kotlin). У URLSession нет OkHttp-цепочки
//  интерсепторов — вместо `AppSignatureInterceptor` (подпись + 403-retry) и внутреннего
//  `ServerTimeInterceptor` (перезаякоривание `TrustedClock` по `Date`) всё складывается в один явный
//  пайплайн внутри `send(...)`. Порядок шагов = порядку OkHttp-цепочки:
//    построить `URLRequest` → подписать 6 заголовками → транспорт с замером RTT → `ServerTimeSampler`
//    → `onServerTime` → 403-retry-once для GET/HEAD при сменившемся `ts`.
//  **Поведенческий контракт с сервером переносится точно** — канонические строки, порядок
//  «сэмпл-до-retry», правила retry и RTT-фильтры зафиксированы Android-тестами (`ApiClientTest.kt`,
//  `SigningTest.kt` retry-матрица).
//
//  Транспорт инжектируется замыканием (идиома `TrustedClock`): прод — `URLSessionTransport` (задача 8),
//  тесты — фейк-очередь. `nowSeconds`/`onServerTime` — `async`-замыкания с inline-`await`: `TrustedClock`
//  actor, его `signingSeconds()`/`onServerTime(…)` изолированы. Fire-and-forget (`Task { … }`) молча
//  сломал бы самолечение 403 — retry-решение прочитало бы `nowSeconds()` до завершения
//  перезаякоривания. Поэтому retry-решение читает `nowSeconds()` строго ПОСЛЕ `await onServerTime`.
//

import Foundation

/// Сетевой доступ к `/app/`-API. Каждый запрос подписывается 6 заголовками `X-App-*`; cloud-клиент
/// перезаякоривает `TrustedClock` по `Date` каждого ответа (включая 403). Ошибки не бросаются —
/// эндпоинты (задача 4) и `post` сворачивают их в `FetchResult`/`PostResult`.
struct ApiClient {
    /// База без завершающего `/` (пути эндпоинтов дают завершающий слэш сами).
    let baseURL: String
    /// `X-App-Key-Id` (= `Secrets.appKeyId`).
    let keyId: String
    /// HMAC-ключ подписи (= `Secrets.appSecret`); НЕ уходит в заголовки.
    let secret: String
    /// `X-Install-Id` (get-or-create UUID этапа 2, читается один раз при вайринге).
    let installId: String
    /// `X-App-Version` (= `CFBundleShortVersionString`).
    let appVersion: String
    /// `X-App-Ts` — unix-**секунды**, читаются заново на retry (= `trustedClock.signingSeconds()`).
    /// `async`: `TrustedClock` — actor.
    let nowSeconds: () async -> Int64
    /// Монотонный `elapsed` в мс (RTT-замер вокруг транспорта; синхронное — обёртка
    /// `mach_continuous_time`).
    let elapsedNowMs: () -> Int64
    /// Приём серверного времени (`TrustedClock.onServerTime`). **nil у LAN-клиента** — LAN-хост
    /// никогда не якорит доверенное время. `async`: `TrustedClock` — actor.
    let onServerTime: ((ServerTimeSample) async -> Void)?
    /// Опаковый bearer-токен админа (`Authorization: Bearer …`) или `nil`. НЕ входит в канонику.
    let tokenProvider: () -> String?
    /// Транспорт-seam: прод — `URLSessionTransport`, тесты — фейк-очередь.
    let transport: (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(
        baseURL: String,
        keyId: String,
        secret: String,
        installId: String,
        appVersion: String,
        nowSeconds: @escaping () async -> Int64,
        elapsedNowMs: @escaping () -> Int64,
        onServerTime: ((ServerTimeSample) async -> Void)? = nil,
        tokenProvider: @escaping () -> String? = { nil },
        transport: @escaping (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) {
        self.baseURL = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        self.keyId = keyId
        self.secret = secret
        self.installId = installId
        self.appVersion = appVersion
        self.nowSeconds = nowSeconds
        self.elapsedNowMs = elapsedNowMs
        self.onServerTime = onServerTime
        self.tokenProvider = tokenProvider
        self.transport = transport
    }

    // MARK: - Generic POST

    /// POST ровно `body`-байтов (по умолчанию `application/json`, переопредели `contentType`) на `url`.
    /// Эти же байты и хэшируются в подпись, и отправляются. `parse` вызывается **только** на
    /// `200`/`201` — тела ошибок не парсятся (пустой POST с `{ Void }`-парсером безопасен). Маппинг:
    /// `200`/`201` → `.success`; `400` → `.badRequest`; `401` → `.unauthorized`; `403` → `.forbidden`;
    /// `409` → `.conflict`; `429` → `.rateLimited`; прочее → `.error(code)`. `URLError` (транспорт) →
    /// `.offline`; ошибка парсинга → `.error(nil)`. **POST не ретраится** (403 неразличим
    /// auth-vs-skew, replay небезопасен) — гарантируется методом POST в `send`.
    func post<T>(
        url: URL,
        body: Data,
        contentType: String = "application/json",
        parse: (Data) throws -> T
    ) async -> PostResult<T> {
        do {
            let (data, response) = try await send(
                method: "POST",
                url: url,
                body: body,
                contentType: contentType,
                ifNoneMatch: nil
            )
            switch response.statusCode {
            case 200, 201:
                return .success(try parse(data))
            case 400:
                return .badRequest
            case 401:
                return .unauthorized
            case 403:
                return .forbidden
            case 409:
                return .conflict
            case 429:
                return .rateLimited
            default:
                return .error(code: response.statusCode)
            }
        } catch is URLError {
            // Транспортный обрыв на POST — офлайн (ожидаемое состояние загрузки на гонке).
            return .offline
        } catch {
            // Ошибка парсинга (или прочее не-URLError) → error(nil).
            return .error(code: nil)
        }
    }

    // MARK: - Эндпоинты (условные GET)

    /// `GET /app/races/`. При `etag != nil` он echo'ится **verbatim, с кавычками** в `If-None-Match`.
    /// `200` → `.success` с распарсенным списком гонок и ETag ответа; `304` → `.notModified`;
    /// `403` → `.forbidden`; прочее → `.error(code)`.
    func fetchRaces(etag: String?) async -> FetchResult<[RaceDto]> {
        await conditionalGet(url: endpoint("/app/races/"), etag: etag) {
            try JSONDecoder().decode(RacesResponse.self, from: $0).races
        }
    }

    /// `GET /app/race/<raceId>/teams/`. Та же условная семантика, что и `fetchRaces`;
    /// `200` → `.success` с распарсенным `TeamsResponse` и ETag ответа.
    func fetchTeams(raceId: Int, etag: String?) async -> FetchResult<TeamsResponse> {
        await conditionalGet(url: endpoint("/app/race/\(raceId)/teams/"), etag: etag) {
            try JSONDecoder().decode(TeamsResponse.self, from: $0)
        }
    }

    /// `GET /app/race/<raceId>/legend/`. Та же условная семантика; `200` → `.success` с
    /// распарсенным `LegendResponse` и ETag. Скрытая легенда всё равно возвращает `200` с пустым
    /// списком `checkpoints`.
    func fetchLegend(raceId: Int, etag: String?) async -> FetchResult<LegendResponse> {
        await conditionalGet(url: endpoint("/app/race/\(raceId)/legend/"), etag: etag) {
            try JSONDecoder().decode(LegendResponse.self, from: $0)
        }
    }

    /// `GET /app/race/<raceId>/member_tags/`. Та же условная семантика; `200` → `.success` с
    /// распарсенным `MemberTagsResponse` (пул NFC-браслетов гонки) и ETag.
    func fetchMemberTags(raceId: Int, etag: String?) async -> FetchResult<MemberTagsResponse> {
        await conditionalGet(url: endpoint("/app/race/\(raceId)/member_tags/"), etag: etag) {
            try JSONDecoder().decode(MemberTagsResponse.self, from: $0)
        }
    }

    /// `GET /app/race/<raceId>/sync/` — lease-манифест локального режима (`data_source` + lease-поля,
    /// см. `SyncManifestDto`). У эндпоинта нет ETag/304 by design, потому `etag` всегда `nil`; `200`
    /// → `.success` с распарсенным манифестом (ETag результата всегда `nil`). Работает через любой
    /// экземпляр `ApiClient` (cloud или LAN). Потребитель-координатор — этап 9.
    func fetchSync(raceId: Int) async -> FetchResult<SyncManifestDto> {
        await conditionalGet(url: endpoint("/app/race/\(raceId)/sync/"), etag: nil) {
            try JSONDecoder().decode(SyncManifestDto.self, from: $0)
        }
    }

    /// URL эндпоинта из `baseURL` (без хвостового `/`) + `path` (с завершающим слэшем — он входит в
    /// подписанную канонику).
    private func endpoint(_ path: String) -> URL {
        URL(string: baseURL + path)!
    }

    /// Общий условный `GET` поверх пайплайна `send`: подписывает/шлёт запрос, echo'ит `etag`
    /// verbatim в `If-None-Match` при `etag != nil`, маппит ответ. `parse` превращает тело `200` в
    /// `T` и вызывается **только** на ветке `200` — тела ошибок/304 не парсятся. `URLError`
    /// (транспорт) и ошибка парсинга сворачиваются в `.error(nil)`; прочие коды → `.error(code)`.
    func conditionalGet<T>(
        url: URL,
        etag: String?,
        parse: (Data) throws -> T
    ) async -> FetchResult<T> {
        do {
            let (data, response) = try await send(
                method: "GET", url: url, body: nil, contentType: nil, ifNoneMatch: etag
            )
            switch response.statusCode {
            case 200:
                // parse вызывается ТОЛЬКО здесь — на не-200 ветках тело не трогаем.
                let parsed = try parse(data)
                return .success(data: parsed, etag: response.value(forHTTPHeaderField: "ETag"))
            case 304:
                return .notModified
            case 403:
                return .forbidden
            default:
                return .error(code: response.statusCode)
            }
        } catch is URLError {
            // Транспортный обрыв на GET → error(nil) (асимметрия с POST → .offline).
            return .error(code: nil)
        } catch {
            // Ошибка парсинга (или прочее не-URLError) → error(nil).
            return .error(code: nil)
        }
    }

    // MARK: - Pipeline (подпись + серверное время + 403-retry)

    /// Единый пайплайн одного запроса (заменяет оба OkHttp-интерсептора). Подписывает `usedTs`,
    /// шлёт через транспорт, сэмплирует `Date`→`onServerTime`, затем читает `nowSeconds()` заново:
    /// при `403 && (GET|HEAD) && nowTs != usedTs` переподписывает свежим `ts` и повторяет **ровно
    /// один раз** (самолечение clock-skew — якорь уже обновлён предыдущим шагом). Возвращает сырой
    /// `(Data, HTTPURLResponse)`; маппинг в result-типы — у `post` (здесь) и `conditionalGet`
    /// (задача 4). Бросает `URLError`/прочее транспорта наружу — сворачивают вызыватели.
    func send(
        method: String,
        url: URL,
        body: Data?,
        contentType: String?,
        ifNoneMatch: String?
    ) async throws -> (Data, HTTPURLResponse) {
        // Тело сериализовано один раз вызывателем; хэшируем ровно эти байты (пусто/GET →
        // EMPTY_BODY_SHA256; пустой POST body тоже даёт EMPTY_BODY_SHA256).
        let bodyHash = body.map { sha256Hex($0) } ?? EMPTY_BODY_SHA256

        let usedTs = await nowSeconds()
        let request = signedRequest(
            method: method, url: url, body: body, contentType: contentType,
            ifNoneMatch: ifNoneMatch, ts: usedTs, bodyHash: bodyHash
        )
        let (data, response) = try await transportAndSample(request)

        // nowSeconds() читается ВСЕГДА и строго ПОСЛЕ `onServerTime` (внутри transportAndSample) —
        // так retry-решение видит уже перезаякоренный `ts` (порядок = OkHttp: outer signature
        // interceptor читает `nowTs` после того, как inner ServerTimeInterceptor отработал в proceed).
        let nowTs = await nowSeconds()
        if response.statusCode == 403,
           method == "GET" || method == "HEAD",
           nowTs != usedTs {
            let retry = signedRequest(
                method: method, url: url, body: body, contentType: contentType,
                ifNoneMatch: ifNoneMatch, ts: nowTs, bodyHash: bodyHash
            )
            return try await transportAndSample(retry)
        }
        return (data, response)
    }

    /// Один проход через транспорт с замером RTT и сэмплом серверного времени (порт внутреннего
    /// `ServerTimeInterceptor`: `Date`-заголовок + midpoint-RTT → `onServerTime`, включая 403).
    private func transportAndSample(
        _ request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        let before = elapsedNowMs()
        let (data, response) = try await transport(request)
        let after = elapsedNowMs()
        if let onServerTime,
           let sample = ServerTimeSampler.sample(
               dateHeader: response.value(forHTTPHeaderField: "Date"),
               requestElapsedMs: before,
               responseElapsedMs: after
           ) {
            await onServerTime(sample)
        }
        return (data, response)
    }

    /// Копия запроса с 6 заголовками подписи (+ опциональный bearer / `If-None-Match`) для `ts`.
    /// `fullPath` = encodedPath + `?query` (то, что реально отправляется — главная причина 403).
    private func signedRequest(
        method: String,
        url: URL,
        body: Data?,
        contentType: String?,
        ifNoneMatch: String?,
        ts: Int64,
        bodyHash: String
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = body
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let tsString = String(ts)
        let canonical = buildCanonical(
            method: method,
            fullPath: Self.fullPath(of: url),
            ts: tsString,
            bodyHash: bodyHash
        )
        let sig = sign(secret: secret, canonical: canonical)

        request.setValue(keyId, forHTTPHeaderField: "X-App-Key-Id")
        request.setValue(sig, forHTTPHeaderField: "X-App-Sig")
        request.setValue(tsString, forHTTPHeaderField: "X-App-Ts")
        request.setValue(installId, forHTTPHeaderField: "X-Install-Id")
        request.setValue("ios", forHTTPHeaderField: "X-App-Platform")
        request.setValue(appVersion, forHTTPHeaderField: "X-App-Version")
        if let token = tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let ifNoneMatch {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }
        return request
    }

    /// encodedPath (+ `?encodedQuery`) — аналог Kotlin `url.encodedPath` + `?url.encodedQuery`.
    /// Именно эта строка входит в подписанную канонику, так что берём проценто-кодированный вид.
    private static func fullPath(of url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            // Не должно случаться для валидных endpoint-URL. Молчаливый fallback на `url.path`
            // отбросил бы query → подпись пошла бы по неверной канонике и словила бы тихий 403,
            // поэтому падаем громко вместо скрытия рассинхрона.
            preconditionFailure("URLComponents failed for endpoint URL: \(url)")
        }
        var path = components.percentEncodedPath
        if let query = components.percentEncodedQuery {
            path += "?" + query
        }
        return path
    }
}
