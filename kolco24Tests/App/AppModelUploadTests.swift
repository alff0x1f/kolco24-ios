//
//  AppModelUploadTests.swift
//  kolco24Tests
//
//  Тесты триггеров выгрузки взятий в `AppModel` (этап 6) — зеркала нет (в Android это инлайн-таймер и
//  flush-корутины в composable), пишутся с нуля поверх РЕАЛЬНЫХ store'ов над `AppDatabase.makeInMemory()`
//  + маршрутизирующий транспорт (не FIFO): смена команды и `.start()`-таймер запускают refresh И выгрузку
//  ОДНОВРЕМЕННО на одном транспорте, поэтому порядок ответов недетерминирован — роутим по URL
//  (`/marks/` → 200 c echo принятых id, всё прочее → 304).
//
//  Проверяем: смена выбранной команды дренит pending-строку; `flushUploads` дренит скоуп; инжектированный
//  интервал 5-мин цикла (без реальных 5 минут) — цикл тикает повторно.
//

import Foundation
import Testing
@testable import kolco24

@MainActor
struct AppModelUploadTests {

    // MARK: - Маршрутизирующий транспорт

    /// Роутит по URL (не FIFO): POST `…/marks/` → 200 `{"accepted":[<все id из тела>]}`; всё прочее → 304.
    /// Так одновременные refresh (GET) и выгрузка (POST) на одном транспорте не зависят от порядка.
    final class RoutingTransport: @unchecked Sendable {
        private let lock = NSLock()
        private var _recorded: [URLRequest] = []

        var recorded: [URLRequest] {
            lock.lock(); defer { lock.unlock() }
            return _recorded
        }

        func handle(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lock.lock(); _recorded.append(request); lock.unlock()
            let url = request.url?.absoluteString ?? ""
            if url.hasSuffix("/marks/") {
                let ids = Self.postedMarkIds(request.httpBody)
                let joined = ids.map { "\"\($0)\"" }.joined(separator: ",")
                let body = Data("{\"accepted\":[\(joined)]}".utf8)
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
                return (body, resp)
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 304, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (Data(), resp)
        }

        /// Извлечь `marks[].id` из тела `MarkUploadRequest` — сервер-эхо принятых id.
        private static func postedMarkIds(_ body: Data?) -> [String] {
            guard let body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let marks = json["marks"] as? [[String: Any]]
            else { return [] }
            return marks.compactMap { $0["id"] as? String }
        }
    }

    // MARK: - Фикстуры

    private func team(id: Int, raceId: Int) -> Team {
        Team(
            id: id, raceId: raceId, teamname: "Барсы", startNumber: "1", categoryId: nil,
            ucount: 2, paidPeople: 2, startTime: 0, finishTime: 0,
            members: [TeamMemberItem(name: "Аня", numberInTeam: 1)]
        )
    }

    private func pendingMark(id: String, raceId: Int, teamId: Int) -> Mark {
        Mark(
            id: id, raceId: raceId, teamId: teamId, checkpointId: 264, checkpointNumber: 12,
            cost: 5, method: "nfc", cpUid: "04A2B3C4D5E680", cpCode: "9f1a2b3c4d5e6f70",
            present: [1], presentDetails: nil, expectedCount: 1, complete: true,
            takenAt: 1000, updatedAt: 1000, uploadedLocal: false, uploadedCloud: false,
            trustedTakenAt: nil, elapsedRealtimeAt: nil, bootCount: nil, locLat: nil, locLon: nil
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()) {
            if clock.now > deadline { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func bothFlagsSet(_ store: MarkStore, _ id: String) async -> Bool {
        guard let mark = try? await store.getById(id) else { return false }
        return mark.uploadedLocal && mark.uploadedCloud
    }

    // MARK: - Смена команды триггерит выгрузку

    @Test func selectingTeam_flushesPendingRow() async throws {
        let transport = RoutingTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.teamStore.insertTeams([team(id: 5, raceId: 7)])
        let model = AppModel(env: env) // дефолтный 5-мин интервал: цикл фаейрится один раз на start

        await model.start()
        await waitUntil { model.selectedTeamState == .none }

        // Строку добавляем ПОСЛЕ старта → immediate-fire цикла (5-мин интервал) её не застал; следующий
        // тик через 5 минут. Значит дренит именно flush смены команды.
        try await env.markStore.upsert(pendingMark(id: "u1", raceId: 7, teamId: 5))
        await model.selectTeam(raceId: 7, teamId: 5)

        await waitUntil { await self.bothFlagsSet(env.markStore, "u1") }
        #expect(await bothFlagsSet(env.markStore, "u1"))
    }

    // MARK: - flushUploads дренит скоуп

    @Test func flushUploads_drainsScope() async throws {
        let transport = RoutingTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        let model = AppModel(env: env)
        // Без `start()` — изолируем `flushUploads` от цикла/наблюдения.
        try await env.markStore.upsert(pendingMark(id: "u1", raceId: 7, teamId: 5))

        model.flushUploads(raceId: 7, teamId: 5) // fire-and-forget

        await waitUntil { await self.bothFlagsSet(env.markStore, "u1") }
        #expect(await bothFlagsSet(env.markStore, "u1"))
    }

    // MARK: - 5-мин цикл: инжектированный интервал → повторный тик

    @Test func uploadLoop_firesOnStartAndRepeatsAtInjectedInterval() async throws {
        let transport = RoutingTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        // Нет выбранной команды → триггер только цикл (не flush смены команды). Малый интервал вместо 5 мин.
        let model = AppModel(env: env, uploadRetryIntervalMs: 50)
        try await env.markStore.upsert(pendingMark(id: "u1", raceId: 7, teamId: 5))

        await model.start() // immediate fire дренит u1

        await waitUntil { await self.bothFlagsSet(env.markStore, "u1") }
        #expect(await bothFlagsSet(env.markStore, "u1"))

        // Вторую строку добавляем после первого прохода — её дренит СЛЕДУЮЩИЙ тик (через ~50 мс),
        // что доказывает повтор цикла без реальных 5 минут.
        try await env.markStore.upsert(pendingMark(id: "u2", raceId: 7, teamId: 5))
        await waitUntil { await self.bothFlagsSet(env.markStore, "u2") }
        #expect(await bothFlagsSet(env.markStore, "u2"))
    }

    // MARK: - scenePhase: фон отменяет цикл, active перезапускает

    @Test func scenePhaseActive_restartsLoopAndDrains() async throws {
        let transport = RoutingTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        let model = AppModel(env: env, uploadRetryIntervalMs: 50)

        await model.start()
        model.scenePhaseChanged(isActive: false) // уход в фон — цикл отменён

        // Пришла новая строка, пока в фоне — на неё никто не среагирует до возврата.
        try await env.markStore.upsert(pendingMark(id: "u1", raceId: 7, teamId: 5))
        model.scenePhaseChanged(isActive: true) // возврат — немедленный fire

        await waitUntil { await self.bothFlagsSet(env.markStore, "u1") }
        #expect(await bothFlagsSet(env.markStore, "u1"))
    }
}
