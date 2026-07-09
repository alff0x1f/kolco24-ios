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

final class FakeTransport {

    private struct Prepared {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    private var queue: [Result<Prepared, Error>] = []

    /// Журнал перехваченных запросов в порядке отправки (проверка заголовков/пути/тела/подписи).
    private(set) var recorded: [URLRequest] = []

    /// Последний перехваченный запрос (частый случай — один вызов на тест).
    var last: URLRequest? { recorded.last }

    /// Сколько раз транспорт реально дёрнули (аналог `proceedCount` из `SigningTest.kt`).
    var callCount: Int { recorded.count }

    func enqueue(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        queue.append(.success(Prepared(statusCode: statusCode, headers: headers, body: body)))
    }

    func enqueue(statusCode: Int, headers: [String: String] = [:], bodyString: String) {
        enqueue(statusCode: statusCode, headers: headers, body: Data(bodyString.utf8))
    }

    /// Транспортный обрыв — `handle` бросит `error` (обычно `URLError`).
    func enqueueError(_ error: Error) {
        queue.append(.failure(error))
    }

    /// Bound-метод для `ApiClient.transport`. Записывает запрос и отдаёт следующий заготовленный
    /// ответ (или бросает заготовленную ошибку).
    func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.append(request)
        precondition(!queue.isEmpty, "FakeTransport: очередь ответов пуста")
        switch queue.removeFirst() {
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
