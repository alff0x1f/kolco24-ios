//
//  TeamModelTests.swift
//  kolco24Tests
//
//  Тесты `TeamModel` — Android-зеркала нет (в Android состояние вкладки живёт в composable), пишутся
//  с нуля поверх РЕАЛЬНЫХ store'ов над `AppDatabase.makeInMemory()` (конвенция этапа 2). Сеть не
//  участвует — таблица `member_chip_bindings` локальная. Проверяем: derived `boundCount`/`allBound`
//  от записей стора, реакцию на upsert/deleteSlot (observation), rebind при смене команды, разрешение
//  категории и **stale-guard** (привязки команды A не видны после rebind на B до её эмиссии).
//
//  observation эмитит асинхронно — состояние ждём поллингом с таймаутом.
//

import Foundation
import Testing
@testable import kolco24

@MainActor
struct TeamModelTests {

    // MARK: - Платформенные фейки (bind-флоу)

    /// Управляемый источник чтений: тест синхронно `emit`'ит `TagReading` в стрим модели.
    final class FakeChipScanner: ChipScanning, @unchecked Sendable {
        private var continuation: AsyncStream<TagReading>.Continuation?
        private(set) var started = false
        private(set) var stopped = false
        func readings() -> AsyncStream<TagReading> {
            AsyncStream { cont in self.continuation = cont }
        }
        func start() { started = true }
        func stop() { stopped = true; continuation?.finish() }
        func emit(_ reading: TagReading) { continuation?.yield(reading) }
    }

    /// Рекордер фидбека (все вызовы на MainActor).
    final class RecordingFeedback: ScanFeedbackPlaying, @unchecked Sendable {
        private(set) var plays: [ScanFeedbackKind] = []
        func play(_ kind: ScanFeedbackKind) { plays.append(kind) }
        func fanfare() {}
        var successCount: Int { plays.filter { if case .success = $0 { return true }; return false }.count }
        var failureCount: Int { plays.filter { if case .failure = $0 { return true }; return false }.count }
        var neutralCount: Int { plays.filter { if case .neutral = $0 { return true }; return false }.count }
    }

    // MARK: - Фикстуры

    private func binding(team: Int, num: Int, uid: String = "AA", pnum: Int) -> MemberChipBinding {
        MemberChipBinding(teamId: team, numberInTeam: num, nfcUid: uid, participantNumber: pnum)
    }

    private func members(_ nums: [Int]) -> [TeamMemberItem] {
        nums.map { TeamMemberItem(name: "Участник \($0)", numberInTeam: $0) }
    }

    private func team(id: Int, raceId: Int, categoryId: Int? = nil) -> Team {
        Team(
            id: id, raceId: raceId, teamname: "Команда", startNumber: "1", categoryId: categoryId,
            ucount: 2, paidPeople: 2, startTime: 0, finishTime: 0,
            members: members([1, 2])
        )
    }

    private func makeEnv() throws -> AppEnvironment {
        try AppEnvironment.inMemory(transport: FakeTransport().handle)
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - boundCount / allBound

    @Test func boundCount_countsOnlyCurrentRosterSlots() async throws {
        let env = try makeEnv()
        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 1, pnum: 100))
        // Устаревшая привязка слота, которого нет в ростере (3) — не должна засчитываться.
        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 3, uid: "BB", pnum: 200))
        let model = TeamModel(env: env)

        model.rebind(teamId: 5)
        await waitUntil { model.bindings.count == 2 }

        let roster = members([1, 2])
        #expect(model.boundCount(members: roster) == 1)
        #expect(model.allBound(members: roster, total: 2) == false)
    }

    // MARK: - Реакция на upsert / deleteSlot

    @Test func reactsToUpsertThenDeleteSlot() async throws {
        let env = try makeEnv()
        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 1, pnum: 100))
        let model = TeamModel(env: env)
        let roster = members([1, 2])

        model.rebind(teamId: 5)
        await waitUntil { model.boundCount(members: roster) == 1 }
        #expect(model.allBound(members: roster, total: 2) == false)

        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 2, uid: "BB", pnum: 200))
        await waitUntil { model.boundCount(members: roster) == 2 }
        #expect(model.allBound(members: roster, total: 2) == true)

        try await env.memberChipBindingStore.deleteSlot(teamId: 5, numberInTeam: 1)
        await waitUntil { model.boundCount(members: roster) == 1 }
        #expect(model.binding(for: 1) == nil)
        #expect(model.binding(for: 2)?.participantNumber == 200)
    }

    // MARK: - unbind (deleteSlot через модель)

    @Test func unbind_removesBinding() async throws {
        let env = try makeEnv()
        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 1, pnum: 100))
        let model = TeamModel(env: env)

        model.rebind(teamId: 5)
        await waitUntil { model.bindings.count == 1 }

        await model.unbind(teamId: 5, numberInTeam: 1)
        await waitUntil { model.bindings.isEmpty }
        #expect(model.binding(for: 1) == nil)
    }

    // MARK: - rebind при смене команды

    @Test func rebind_switchesToOtherTeamBindings() async throws {
        let env = try makeEnv()
        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 1, pnum: 100))
        try await env.memberChipBindingStore.upsert(binding(team: 6, num: 1, uid: "BB", pnum: 300))
        let model = TeamModel(env: env)

        model.rebind(teamId: 5)
        await waitUntil { model.binding(for: 1)?.participantNumber == 100 }

        model.rebind(teamId: 6)
        await waitUntil { model.binding(for: 1)?.participantNumber == 300 }
        #expect(model.bindings.count == 1)
    }

    // MARK: - Stale-guard

    @Test func rebind_clearsPreviousTeamBindingsSynchronously() async throws {
        let env = try makeEnv()
        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 1, pnum: 100))
        let model = TeamModel(env: env)

        model.rebind(teamId: 5)
        await waitUntil { !model.bindings.isEmpty }

        // Смена команды очищает привязки прежней синхронно (до первой эмиссии новой).
        model.rebind(teamId: 6)
        #expect(model.bindings.isEmpty)
    }

    // MARK: - Категория гонки

    @Test func category_resolvedFromRaceCategories() async throws {
        let env = try makeEnv()
        try await env.teamStore.insertCategories([
            kolco24.Category(id: 100, raceId: 3, code: "A", shortName: "12ч", name: "12 часов", sortOrder: 1),
        ])
        let model = TeamModel(env: env)
        let t = team(id: 10, raceId: 3, categoryId: 100)

        model.rebind(teamId: 10, raceId: 3)
        await waitUntil { !model.categories.isEmpty }

        #expect(model.category(for: t)?.id == 100)
        #expect(model.category(for: team(id: 11, raceId: 3, categoryId: nil)) == nil)
    }

    // MARK: - nil-команда снимает наблюдение

    @Test func rebindNil_clearsBindings() async throws {
        let env = try makeEnv()
        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 1, pnum: 100))
        let model = TeamModel(env: env)

        model.rebind(teamId: 5)
        await waitUntil { !model.bindings.isEmpty }

        model.rebind(teamId: nil)
        #expect(model.bindings.isEmpty)
    }

    // MARK: - Bind-флоу (задача 9)

    private let bindRace = 3
    private let bindTeam = 5

    private func reading(uid: String) -> TagReading {
        TagReading(
            code: nil, uid: uid,
            sample: TimeSample(wallMs: 0, elapsedMs: 0, trustedMs: nil, bootCount: nil)
        )
    }

    private func member(_ num: Int) -> TeamMemberItem {
        TeamMemberItem(name: "Участник \(num)", numberInTeam: num)
    }

    /// Заполняет пул member-тегов гонки (непустой пул → bind не дёргает refresh).
    private func fillPool(_ env: AppEnvironment, _ tags: [(uid: String, number: Int)]) async throws {
        try await env.memberTagStore.insertAll(
            tags.map { MemberTag(raceId: bindRace, nfcUid: $0.uid, number: $0.number) }
        )
    }

    /// Прочитанный uid не из пула → `notInPool` + failure-фидбек, ничего не записано.
    @Test func bind_notInPool() async throws {
        let feedback = RecordingFeedback()
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle, feedback: feedback)
        try await fillPool(env, [(uid: "AA", number: 101)])
        let model = TeamModel(env: env)
        model.rebind(teamId: bindTeam, raceId: bindRace)

        let scanner = FakeChipScanner()
        model.beginBind(member: member(1), scanner: scanner)
        scanner.emit(reading(uid: "ZZ"))

        await waitUntil { model.bindState == .notInPool(uid: "ZZ") }
        #expect(model.bindState == .notInPool(uid: "ZZ"))
        #expect(feedback.failureCount == 1)
        #expect(try await env.memberChipBindingStore.findByUid("ZZ") == nil)
    }

    /// Свободный чип из пула → `reassign` записал слот + `success`.
    @Test func bind_readyToBind_writesSlot() async throws {
        let feedback = RecordingFeedback()
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle, feedback: feedback)
        try await fillPool(env, [(uid: "AA", number: 101)])
        let model = TeamModel(env: env)
        model.rebind(teamId: bindTeam, raceId: bindRace)

        let scanner = FakeChipScanner()
        model.beginBind(member: member(1), scanner: scanner)
        scanner.emit(reading(uid: "AA"))

        await waitUntil { model.bindState == .success(participantNumber: 101) }
        #expect(feedback.successCount == 1)
        let bound = try await env.memberChipBindingStore.findByUid("AA")
        #expect(bound?.teamId == bindTeam)
        #expect(bound?.numberInTeam == 1)
        #expect(bound?.participantNumber == 101)
    }

    /// Чип занят другим слотом → `alreadyBound` (neutral, без записи); после подтверждения слот переехал
    /// (старый слот пуст).
    @Test func bind_alreadyBound_confirmMovesSlot() async throws {
        let feedback = RecordingFeedback()
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle, feedback: feedback)
        try await fillPool(env, [(uid: "AA", number: 101)])
        // Чип "AA" уже висит на слоте 2.
        try await env.memberChipBindingStore.upsert(
            MemberChipBinding(teamId: bindTeam, numberInTeam: 2, nfcUid: "AA", participantNumber: 101)
        )
        let model = TeamModel(env: env)
        model.rebind(teamId: bindTeam, raceId: bindRace)
        await waitUntil { model.binding(for: 2)?.nfcUid == "AA" }

        let scanner = FakeChipScanner()
        model.beginBind(member: member(1), scanner: scanner)
        scanner.emit(reading(uid: "AA"))

        await waitUntil { model.bindState == .alreadyBound(uid: "AA", participantNumber: 101) }
        #expect(feedback.neutralCount == 1)
        // Ещё ничего не переехало.
        #expect(model.binding(for: 2)?.nfcUid == "AA")
        #expect(try await env.memberChipBindingStore.findByUid("AA")?.numberInTeam == 2)

        // Подтверждение перепривязки → слот 1 получает чип, слот 2 очищается.
        await model.confirmReassign()
        await waitUntil { model.bindState == .success(participantNumber: 101) }
        await waitUntil { model.binding(for: 1)?.nfcUid == "AA" && model.binding(for: 2) == nil }
        #expect(try await env.memberChipBindingStore.findByUid("AA")?.numberInTeam == 1)
    }

    /// Чип уже ровно на этом слоте → `success` с перезаписью `participantNumber` из пула (стейл-номер
    /// обновляется).
    @Test func bind_alreadyOnThisSlot() async throws {
        let feedback = RecordingFeedback()
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle, feedback: feedback)
        try await fillPool(env, [(uid: "AA", number: 101)])
        // Слот 1 уже держит "AA", но со стейл-номером 999.
        try await env.memberChipBindingStore.upsert(
            MemberChipBinding(teamId: bindTeam, numberInTeam: 1, nfcUid: "AA", participantNumber: 999)
        )
        let model = TeamModel(env: env)
        model.rebind(teamId: bindTeam, raceId: bindRace)
        await waitUntil { model.binding(for: 1)?.nfcUid == "AA" }

        let scanner = FakeChipScanner()
        model.beginBind(member: member(1), scanner: scanner)
        scanner.emit(reading(uid: "AA"))

        await waitUntil { model.bindState == .success(participantNumber: 101) }
        #expect(feedback.successCount == 1)
        // Номер перезаписан авторитетным пулом (999 → 101).
        #expect(try await env.memberChipBindingStore.findByUid("AA")?.participantNumber == 101)
    }

    /// Пул пуст и не синхронизирован → `poolNotReady`-ветка дёргает `refreshMemberTags` (журнал
    /// `FakeTransport`); при офлайне возврат в ожидание + neutral. Refresh зовётся ТОЛЬКО из этой ветки,
    /// поэтому запись в журнале доказывает, что `poolNotReady` отработал.
    @Test func bind_poolEmptyNotSynced_triggersRefresh() async throws {
        let feedback = RecordingFeedback()
        let transport = FakeTransport()
        transport.enqueueError(URLError(.notConnectedToInternet))   // офлайн-обрыв member_tags GET
        let env = try AppEnvironment.inMemory(transport: transport.handle, feedback: feedback)
        // Пул пуст, sync_meta нет → hasBeenSynced == false.
        let model = TeamModel(env: env)
        model.rebind(teamId: bindTeam, raceId: bindRace)

        let scanner = FakeChipScanner()
        model.beginBind(member: member(1), scanner: scanner)
        scanner.emit(reading(uid: "AA"))

        await waitUntil { transport.callCount >= 1 }
        #expect(transport.last?.url?.path.contains("member_tags") == true)
        // Офлайн-исход refresh: назад в ожидание + neutral, привязка не записана.
        await waitUntil { feedback.neutralCount == 1 }
        #expect(model.bindState == .waiting)
        #expect(try await env.memberChipBindingStore.findByUid("AA") == nil)
    }

    /// `confirmReassign` вне состояния `alreadyBound` — no-op (гвард), состояние не меняется, записи нет.
    @Test func confirmReassign_noopWhenNotAlreadyBound() async throws {
        let feedback = RecordingFeedback()
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle, feedback: feedback)
        try await fillPool(env, [(uid: "AA", number: 101)])
        let model = TeamModel(env: env)
        model.rebind(teamId: bindTeam, raceId: bindRace)

        let scanner = FakeChipScanner()
        model.beginBind(member: member(1), scanner: scanner)
        // Состояние .waiting (чип не поднесён) → confirmReassign обязан ничего не сделать.
        await model.confirmReassign()

        #expect(model.bindState == .waiting)
        #expect(feedback.plays.isEmpty)
        #expect(try await env.memberChipBindingStore.findByUid("AA") == nil)
    }

    /// Гейт для детерминированной остановки `refreshMemberTags` внутри `processBind`.
    actor AsyncGate {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if released { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            released = true
            let pending = waiters
            waiters.removeAll()
            for w in pending { w.resume() }
        }
    }

    /// Stale-guard: если лист закрыли (`cancelBind`), пока `processBind` висел на `await refreshMemberTags`,
    /// резюмировавшийся скан НЕ пишет привязку и НЕ трогает состояние (не переезжает в success/notInPool) —
    /// иначе он бы привязал уже неактуального участника или клоббернул переоткрытый лист.
    @Test func staleScanAfterCancelDoesNotBindOrClobberState() async throws {
        let gate = AsyncGate()
        let feedback = RecordingFeedback()
        // member_tags GET виснет на гейте → детерминированное окно, в котором лист отменяют. После
        // release сервер отдаёт 200 с "AA" (был бы readyToBind), но stale-guard обязан ничего не сделать.
        let body = #"{"member_tags":[{"number":101,"nfc_uid":"AA"}]}"#
        let transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) = { req in
            await gate.wait()
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (Data(body.utf8), resp)
        }
        let env = try AppEnvironment.inMemory(transport: transport, feedback: feedback)
        // Пул пуст и не синхронизирован → processBind уходит в poolNotReady и виснет на refresh.
        let model = TeamModel(env: env)
        model.rebind(teamId: bindTeam, raceId: bindRace)

        let scanner = FakeChipScanner()
        model.beginBind(member: member(1), scanner: scanner)
        scanner.emit(reading(uid: "AA"))

        // processBind выставляет .poolNotReady ровно перед `await refreshMemberTags` — значит он висит на гейте.
        await waitUntil { model.bindState == .poolNotReady }
        // Пользователь закрывает лист, пока идёт refresh.
        model.cancelBind()
        #expect(model.bindMember == nil)
        // Отпускаем refresh: processBind резюмируется и обязан увидеть stale → выйти без записи/мутации.
        await gate.release()
        try? await Task.sleep(for: .milliseconds(150))

        #expect(try await env.memberChipBindingStore.findByUid("AA") == nil)
        #expect(model.bindState == .waiting)
        #expect(feedback.successCount == 0)
    }
}
