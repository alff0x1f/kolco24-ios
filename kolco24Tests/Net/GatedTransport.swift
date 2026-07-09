//
//  GatedTransport.swift
//  kolco24Tests
//
//  Транспорт-замыкание с УПРАВЛЯЕМОЙ задержкой — для детерминированной проверки stale-write'ов
//  (гонка/команда сменилась, пока refresh был «в полёте»). Запросы к URL с суффиксом `gateSuffix`
//  зависают, пока тест не вызовет `release(...)`; все остальные отвечают немедленно (по умолчанию
//  `304` — безопасно для любого условного GET, тело не парсится). Потокобезопасен (`NSLock`) —
//  этап 4 бьёт транспорт из параллельных fan-out'ов.
//

import Foundation

final class GatedTransport: @unchecked Sendable {

    private let lock = NSLock()
    private var _recorded: [URLRequest] = []
    private let gateSuffix: String
    private var pending: [CheckedContinuation<Void, Never>] = []
    /// Исход зажатого запроса после `release`: либо ошибка, либо статус-код.
    private var released: Result<Int, Error>?

    /// - Parameter gateSuffix: суффикс URL, запросы к которому висят до `release`.
    init(gateSuffix: String) {
        self.gateSuffix = gateSuffix
    }

    var recorded: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _recorded
    }

    func requested(suffix: String) -> Bool {
        recorded.contains { $0.url?.absoluteString.hasSuffix(suffix) ?? false }
    }

    /// Освобождает зажатый запрос транспортным обрывом (`URLError` → `.offline` у клиента).
    func release(error: Error) { release(with: .failure(error)) }

    /// Освобождает зажатый запрос статус-кодом (по умолчанию `304 Not Modified`).
    func release(statusCode: Int = 304) { release(with: .success(statusCode)) }

    private func release(with outcome: Result<Int, Error>) {
        let conts: [CheckedContinuation<Void, Never>] = {
            lock.lock(); defer { lock.unlock() }
            released = outcome
            let c = pending; pending = []
            return c
        }()
        conts.forEach { $0.resume() }
    }

    /// Bound-метод для `ApiClient.transport`.
    func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let isGated: Bool = {
            lock.lock(); defer { lock.unlock() }
            _recorded.append(request)
            return request.url?.absoluteString.hasSuffix(gateSuffix) ?? false
        }()

        guard isGated else { return response(request, statusCode: 304) }

        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released != nil {
                lock.unlock(); c.resume()
            } else {
                pending.append(c); lock.unlock()
            }
        }

        let outcome: Result<Int, Error> = {
            lock.lock(); defer { lock.unlock() }
            return released!
        }()
        switch outcome {
        case .failure(let error): throw error
        case .success(let statusCode): return response(request, statusCode: statusCode)
        }
    }

    private func response(_ request: URLRequest, statusCode: Int) -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: [:]
        )!
        return (Data(), response)
    }
}
