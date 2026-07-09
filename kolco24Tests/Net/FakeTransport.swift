//
//  FakeTransport.swift
//  kolco24Tests
//
//  Транспорт-замыкание-фейк — замена OkHttp `MockWebServer` из Android-тестов: очередь заготовленных
//  `(статус, заголовки, тело)` ответов + журнал перехваченных `URLRequest`. Без сети и глобального
//  состояния. Общий для задач 3–8 (`ApiClientTests`, `*RepositoryTests`).
//
//  Отдаётся `ApiClient.transport` как bound-метод `handle`. `HTTPURLResponse` строится в момент
//  вызова из `request.url` (url ответа = url запроса, как у `MockWebServer`). `enqueueError`
//  моделирует транспортный обрыв (`URLError` → `.offline`/`.error(nil)` у клиента).
//

import Foundation

/// Потокобезопасен (`@unchecked Sendable` + `NSLock`): этап 4 гоняет параллельные fan-out'ы
/// (`async let` refreshTeams/refreshLegend/refreshMemberTags), которые бьют `handle` из нескольких
/// задач одновременно — без замка одновременная мутация `queue`/`recorded` (Swift Array) = UB/креш.
final class FakeTransport: @unchecked Sendable {

    private struct Prepared {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    private let lock = NSLock()
    private var _queue: [Result<Prepared, Error>] = []
    private var _recorded: [URLRequest] = []

    /// Журнал перехваченных запросов в порядке отправки (проверка заголовков/пути/тела/подписи).
    var recorded: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _recorded
    }

    /// Последний перехваченный запрос (частый случай — один вызов на тест).
    var last: URLRequest? { recorded.last }

    /// Сколько раз транспорт реально дёрнули (аналог `proceedCount` из `SigningTest.kt`).
    var callCount: Int { recorded.count }

    func enqueue(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        lock.lock(); defer { lock.unlock() }
        _queue.append(.success(Prepared(statusCode: statusCode, headers: headers, body: body)))
    }

    func enqueue(statusCode: Int, headers: [String: String] = [:], bodyString: String) {
        enqueue(statusCode: statusCode, headers: headers, body: Data(bodyString.utf8))
    }

    /// Транспортный обрыв — `handle` бросит `error` (обычно `URLError`).
    func enqueueError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        _queue.append(.failure(error))
    }

    /// Bound-метод для `ApiClient.transport`. Записывает запрос и отдаёт следующий заготовленный
    /// ответ (или бросает заготовленную ошибку).
    func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let next: Result<Prepared, Error> = {
            lock.lock(); defer { lock.unlock() }
            _recorded.append(request)
            precondition(!_queue.isEmpty, "FakeTransport: очередь ответов пуста")
            return _queue.removeFirst()
        }()
        switch next {
        case .failure(let error):
            throw error
        case .success(let prepared):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: prepared.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: prepared.headers
            )!
            return (prepared.body, response)
        }
    }
}
