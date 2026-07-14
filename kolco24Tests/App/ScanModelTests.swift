//
//  ScanModelTests.swift
//  kolco24Tests
//
//  Тесты `ScanModel` — Android-зеркала нет (логика размазана по `MainActivity`/`ScanScreen`), пишутся
//  с нуля поверх РЕАЛЬНЫХ store'ов над `AppDatabase.makeInMemory()` + фейков только на платформенных
//  границах (`FakeChipScanner`, `FakeLocationProvider`, фидбек-рекордер) и управляемого времени
//  (инжектированные `elapsedNowMs` + `sample.elapsedMs` в чтениях). Проверяем поведенческую
//  спецификацию Technical Details §1–10.
//
//  Чип КП в тестах поднимается через identity-only тег (`iv==nil && ct==nil`): `LegendRepository.unlock`
//  возвращает `.identityOnly(checkpointId)` без полной крипто-обвязки, `classifyTag` резолвит цену из
//  снимка КП — так весь скан-флоу гоняется на реальном unlock без KAT-векторов.
//

import Foundation
import Testing
@testable import kolco24

@MainActor
struct ScanModelTests {

    // MARK: - Платформенные фейки

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
        func finish() { continuation?.finish() }
    }

    /// One-shot GPS-фейк со счётчиком вызовов (актор — читается без гонок из detached-Task attach'а).
    actor RecordingLocationProvider: CurrentLocationProvider {
        let fix: RawFix?
        private(set) var callCount = 0
        init(fix: RawFix?) { self.fix = fix }
        func current(timeoutMs: Int64) async -> RawFix? {
            callCount += 1
            return fix
        }
    }

    /// Рекордер фидбека (класс — все вызовы происходят на MainActor: `finish` и фанфар-Task наследуют изоляцию).
    final class RecordingFeedback: ScanFeedbackPlaying, @unchecked Sendable {
        private(set) var plays: [ScanFeedbackKind] = []
        private(set) var fanfares = 0
        func play(_ kind: ScanFeedbackKind) { plays.append(kind) }
        func fanfare() { fanfares += 1 }
        var successCount: Int { plays.filter { if case .success = $0 { return true }; return false }.count }
        var failureCount: Int { plays.filter { if case .failure = $0 { return true }; return false }.count }
    }

    /// Управляемый монотонный `elapsedMs` для таймера окна.
    actor FakeElapsed {
        private var ms: Int64
        init(_ ms: Int64 = 0) { self.ms = ms }
        func set(_ value: Int64) { ms = value }
        func get() -> Int64 { ms }
    }

    /// Детерминированный генератор id взятия.
    final class IdGen: @unchecked Sendable {
        private var n = 0
        func next() -> String { n += 1; return "mark-\(n)" }
    }

    // MARK: - Фикстуры

    private let race = 7
    private let team = 42

    private func makeEnv() throws -> AppEnvironment {
        try AppEnvironment.inMemory(transport: FakeTransport().handle)
    }

    private func members(_ nums: [Int]) -> [TeamMemberItem] {
        nums.map { TeamMemberItem(name: "Участник \($0)", numberInTeam: $0) }
    }

    /// Регистрирует открытый КП + identity-only тег, чей `bid = sha256(code)[:16]` матчит `code`.
    private func registerKp(_ env: AppEnvironment, cpId: Int, number: Int, cost: Int, code: Data) async throws {
        try await env.checkpointStore.insertCheckpoints([
            Checkpoint(id: cpId, raceId: race, number: number, cost: cost, type: "cp",
                       description: "КП \(number)", locked: false)
        ])
        let bid = LegendCrypto.bid(code: code)
        try await env.tagStore.insertTags([
            Tag(raceId: race, bid: bid, checkpointId: cpId, checkMethod: "nfc", iv: nil, ct: nil)
        ])
    }

    private func bind(_ env: AppEnvironment, slot: Int, uid: String, pnum: Int) async throws {
        try await env.memberChipBindingStore.upsert(
            MemberChipBinding(teamId: team, numberInTeam: slot, nfcUid: uid, participantNumber: pnum)
        )
    }

    private func reading(code: Data?, uid: String, elapsed: Int64, wall: Int64? = nil) -> TagReading {
        TagReading(
            code: code, uid: uid,
            sample: TimeSample(wallMs: wall ?? elapsed, elapsedMs: elapsed, trustedMs: nil, bootCount: nil)
        )
    }

    private func kpCode(_ seed: UInt8) -> Data { Data((0..<16).map { UInt8(($0 + Int(seed)) & 0xFF) }) }

    private func validFix() -> RawFix {
        RawFix(lat: 55.75, lon: 37.61, accuracy: 5, altitude: 150, verticalAccuracyMeters: 3,
               gpsTimeMs: 1_700_000_000_000, elapsedRealtimeNanos: 500_000_000)
    }

    private func makeModel(
        env: AppEnvironment,
        roster: [TeamMemberItem],
        scanner: FakeChipScanner,
        feedback: RecordingFeedback = RecordingFeedback(),
        location: any CurrentLocationProvider = RecordingLocationProvider(fix: nil),
        elapsed: FakeElapsed = FakeElapsed(),
        ids: IdGen = IdGen(),
        tickMs: Int64 = 3_600_000,
        fanfareDelayMs: Int64 = 0,
        successHoldMs: Int64 = 3_600_000
    ) -> ScanModel {
        ScanModel(
            raceId: race, teamId: team, roster: roster,
            legendRepository: env.legendRepository, markStore: env.markStore,
            bindingStore: env.memberChipBindingStore, locationProvider: location,
            feedback: feedback, elapsedNowMs: { await elapsed.get() },
            newMarkId: { ids.next() },
            tickMs: tickMs, fanfareDelayMs: fanfareDelayMs, successHoldMs: successHoldMs
        )
    }

    private func poll(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()) {
            if clock.now > deadline { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - КП → участники → complete (+фанфары)

    @Test func kpThenMembersCompletesWithFanfare() async throws {
        let env = try makeEnv()
        let code = kpCode(1)
        try await registerKp(env, cpId: 100, number: 32, cost: 4, code: code)
        try await bind(env, slot: 1, uid: "M1", pnum: 101)

        let scanner = FakeChipScanner()
        let feedback = RecordingFeedback()
        let model = makeModel(env: env, roster: members([1]), scanner: scanner, feedback: feedback)
        model.start(scanner: scanner)
        await poll { model.bindings["M1"] == 1 }

        scanner.emit(reading(code: code, uid: "CP", elapsed: 0))
        await poll { model.session?.checkpointId == 100 }
        #expect(model.session?.checkpointNumber == 32)
        #expect(model.session?.cost == 4)

        scanner.emit(reading(code: nil, uid: "M1", elapsed: 100))
        await poll { model.session?.present == [1] }
        #expect(isComplete(session: model.session, rosterSize: 1))
        await poll { feedback.fanfares >= 1 }
        #expect(feedback.fanfares == 1)
        #expect(feedback.successCount >= 2)   // КП + завершающий участник
        #expect(model.completed == true)

        // Персист: строка взятия дошла до БД с полным ростером и complete.
        await poll { (try? await env.markStore.getById("mark-1"))??.present == [1] }
        let mark = try #require(try await env.markStore.getById("mark-1"))
        #expect(mark.present == [1])
        #expect(mark.complete == true)
        #expect(mark.checkpointNumber == 32)
    }

    // MARK: - Участники до КП → буфер сливается в present

    @Test func membersBeforeKpDrainIntoPresent() async throws {
        let env = try makeEnv()
        let code = kpCode(2)
        try await registerKp(env, cpId: 100, number: 10, cost: 3, code: code)
        try await bind(env, slot: 1, uid: "M1", pnum: 101)
        try await bind(env, slot: 2, uid: "M2", pnum: 102)

        let scanner = FakeChipScanner()
        let model = makeModel(env: env, roster: members([1, 2]), scanner: scanner)
        model.start(scanner: scanner)
        await poll { model.bindings.count == 2 }

        scanner.emit(reading(code: nil, uid: "M1", elapsed: 0))
        await poll { model.session?.bufferedBeforeKp == [1] }
        scanner.emit(reading(code: nil, uid: "M2", elapsed: 50))
        await poll { model.session?.bufferedBeforeKp == [1, 2] }
        #expect(model.session?.present.isEmpty == true)   // ещё нет КП

        scanner.emit(reading(code: code, uid: "CP", elapsed: 100))
        await poll { model.session?.checkpointId == 100 }
        #expect(model.session?.present == [1, 2])          // буфер слит
        #expect(model.session?.bufferedBeforeKp.isEmpty == true)

        // Персист: present[] и снимки участников с их participantNumber.
        await poll { (try? await env.markStore.getById("mark-1"))??.present.count == 2 }
        let mark = try #require(try await env.markStore.getById("mark-1"))
        #expect(Set(mark.present) == [1, 2])
        #expect(Set((mark.presentDetails ?? []).map { $0.number }) == [101, 102])
    }

    // MARK: - Истечение окна перед КП → буфер/снапшоты чищены

    @Test func expiredWindowClearsBufferBeforeNewTake() async throws {
        let env = try makeEnv()
        let code = kpCode(3)
        try await registerKp(env, cpId: 100, number: 5, cost: 2, code: code)
        try await bind(env, slot: 1, uid: "M1", pnum: 101)

        let scanner = FakeChipScanner()
        let model = makeModel(env: env, roster: members([1, 2]), scanner: scanner)
        model.start(scanner: scanner)
        await poll { model.bindings["M1"] == 1 }

        // Участник в буфер, затем окно истекает (следующий скан спустя > 20 с).
        scanner.emit(reading(code: nil, uid: "M1", elapsed: 0))
        await poll { model.session?.bufferedBeforeKp == [1] }

        scanner.emit(reading(code: code, uid: "CP", elapsed: SCAN_WINDOW_MS + 500))
        await poll { model.session?.checkpointId == 100 }
        // Буфер мёртвой сессии сброшен — участник не кредитуется новому взятию.
        #expect(model.session?.present.isEmpty == true)

        await poll { (try? await env.markStore.getById("mark-1")) != nil }
        let mark = try #require(try await env.markStore.getById("mark-1"))
        #expect(mark.present.isEmpty)
    }

    // MARK: - Участник после истечения окна → полный сброс take-state, свежий буфер

    @Test func memberAfterExpiryResetsTakeStateNotCreditedToDeadTake() async throws {
        let env = try makeEnv()
        let code1 = kpCode(4)
        let code2 = kpCode(40)
        try await registerKp(env, cpId: 100, number: 5, cost: 2, code: code1)
        try await registerKp(env, cpId: 200, number: 6, cost: 3, code: code2)
        try await bind(env, slot: 1, uid: "M1", pnum: 101)
        try await bind(env, slot: 2, uid: "M2", pnum: 102)

        let scanner = FakeChipScanner()
        let model = makeModel(env: env, roster: members([1, 2]), scanner: scanner)
        model.start(scanner: scanner)
        await poll { model.bindings.count == 2 }

        // Взятие КП1 + участник 1.
        scanner.emit(reading(code: code1, uid: "CP1", elapsed: 0))
        await poll { model.session?.checkpointId == 100 }
        scanner.emit(reading(code: nil, uid: "M1", elapsed: 100))
        await poll { model.session?.present == [1] }
        await poll { (try? await env.markStore.getById("mark-1"))??.present == [1] }

        // Участник 2 ПОСЛЕ истечения окна → полный сброс: свежая сессия, только буфер {2}.
        scanner.emit(reading(code: nil, uid: "M2", elapsed: SCAN_WINDOW_MS + 500))
        await poll { model.session?.bufferedBeforeKp == [2] }
        #expect(model.session?.checkpointId == nil)
        #expect(model.session?.present.isEmpty == true)

        // Мёртвое взятие КП1 не получило участника 2.
        let dead = try #require(try await env.markStore.getById("mark-1"))
        #expect(dead.present == [1])

        // Новый КП2 → свежее взятие только с участником 2.
        scanner.emit(reading(code: code2, uid: "CP2", elapsed: SCAN_WINDOW_MS + 600))
        await poll { model.session?.checkpointId == 200 }
        #expect(model.session?.present == [2])
        await poll { (try? await env.markStore.getById("mark-2"))??.present == [2] }
        let fresh = try #require(try await env.markStore.getById("mark-2"))
        #expect(fresh.present == [2])
        #expect(fresh.checkpointId == 200)
    }

    // MARK: - Смена КП сбрасывает present

    @Test func kpSwitchResetsPresent() async throws {
        let env = try makeEnv()
        let code1 = kpCode(5)
        let code2 = kpCode(55)
        try await registerKp(env, cpId: 100, number: 5, cost: 2, code: code1)
        try await registerKp(env, cpId: 200, number: 6, cost: 3, code: code2)
        try await bind(env, slot: 1, uid: "M1", pnum: 101)

        let scanner = FakeChipScanner()
        let model = makeModel(env: env, roster: members([1, 2]), scanner: scanner)
        model.start(scanner: scanner)
        await poll { model.bindings["M1"] == 1 }

        scanner.emit(reading(code: code1, uid: "CP1", elapsed: 0))
        await poll { model.session?.checkpointId == 100 }
        scanner.emit(reading(code: nil, uid: "M1", elapsed: 100))
        await poll { model.session?.present == [1] }

        // Другой КП в живом окне → новое взятие, present сброшен (участники были на другом пункте).
        scanner.emit(reading(code: code2, uid: "CP2", elapsed: 200))
        await poll { model.session?.checkpointId == 200 }
        #expect(model.session?.checkpointNumber == 6)
        #expect(model.session?.present.isEmpty == true)
    }

    // MARK: - unbound / badKp: окно не двигается + failure-фидбек

    @Test func unboundAndBadKpDoNotMoveWindowAndPlayFailure() async throws {
        let env = try makeEnv()
        let code = kpCode(6)
        try await registerKp(env, cpId: 100, number: 5, cost: 2, code: code)
        try await bind(env, slot: 1, uid: "M1", pnum: 101)

        let scanner = FakeChipScanner()
        let feedback = RecordingFeedback()
        let model = makeModel(env: env, roster: members([1]), scanner: scanner, feedback: feedback)
        model.start(scanner: scanner)
        await poll { model.bindings["M1"] == 1 }

        scanner.emit(reading(code: code, uid: "CP", elapsed: 0))
        await poll { model.session?.checkpointId == 100 }
        let stampedAt = model.session?.lastScanAt

        // Непривязанный браслет (uid не в bindings).
        scanner.emit(reading(code: nil, uid: "ZZ", elapsed: 300))
        await poll { model.diagnostic == "Чип не привязан к команде" }
        #expect(model.session?.lastScanAt == stampedAt)   // окно не сдвинулось

        // Чужой чип КП (нет тега с таким bid → unknown).
        scanner.emit(reading(code: kpCode(200), uid: "XX", elapsed: 600))
        await poll { model.diagnostic == "неизвестный чип" }
        #expect(model.session?.lastScanAt == stampedAt)
        #expect(feedback.failureCount == 2)
    }

    // MARK: - Повторный участник идемпотентен и не перештамповывает окно

    @Test func repeatMemberIsIdempotentAndDoesNotRestampWindow() async throws {
        let env = try makeEnv()
        let code = kpCode(7)
        try await registerKp(env, cpId: 100, number: 5, cost: 2, code: code)
        try await bind(env, slot: 1, uid: "M1", pnum: 101)

        let scanner = FakeChipScanner()
        let feedback = RecordingFeedback()
        let model = makeModel(env: env, roster: members([1, 2]), scanner: scanner, feedback: feedback)
        model.start(scanner: scanner)
        await poll { model.bindings["M1"] == 1 }

        scanner.emit(reading(code: code, uid: "CP", elapsed: 0))
        await poll { model.session?.checkpointId == 100 }
        scanner.emit(reading(code: nil, uid: "M1", elapsed: 100))
        await poll { model.session?.present == [1] }
        #expect(model.session?.lastScanAt == 100)
        let successBeforeRepeat = feedback.successCount

        // Повтор того же участника в живом окне — идемпотентно, окно НЕ перештамповано. Негативное
        // утверждение не вакуумно: повтор всё равно проигрывает success-фидбек, поэтому дожидаемся его
        // инкремента как доказательства, что скан ОБРАБОТАН, и лишь тогда проверяем, что окно не сдвинулось.
        scanner.emit(reading(code: nil, uid: "M1", elapsed: 5_000))
        await poll { feedback.successCount == successBeforeRepeat + 1 }
        #expect(feedback.successCount == successBeforeRepeat + 1)
        #expect(model.session?.present == [1])
        #expect(model.session?.lastScanAt == 100)   // не 5_000
    }

    // MARK: - «Закрытие шита» не обрывает персист (§6)

    @Test func sheetCloseDoesNotAbortPersist() async throws {
        let env = try makeEnv()
        let code = kpCode(8)
        try await registerKp(env, cpId: 100, number: 5, cost: 7, code: code)

        let scanner = FakeChipScanner()
        let model = makeModel(env: env, roster: members([1]), scanner: scanner)
        model.start(scanner: scanner)

        scanner.emit(reading(code: code, uid: "CP", elapsed: 0))
        await poll { model.session?.checkpointId == 100 }
        // Немедленно «закрываем шит».
        model.stop()

        // Персист живёт в отдельном Task (захватил стор) — переживает stop().
        await poll { (try? await env.markStore.getById("mark-1")) != nil }
        let mark = try #require(try await env.markStore.getById("mark-1"))
        #expect(mark.cost == 7)

        // Конец стрима (§6) закрывает оверлей через `requestClose`, но это НЕ успешное завершение —
        // `didComplete` остаётся false (конфетти на «Отметках» не запускается).
        await poll { model.closeRequested }
        #expect(model.closeRequested == true)
        #expect(model.didComplete == false)
    }

    // MARK: - GPS-attach один раз, не трогает present

    @Test func gpsAttachedOnceAndDoesNotTouchPresent() async throws {
        let env = try makeEnv()
        let code = kpCode(9)
        try await registerKp(env, cpId: 100, number: 5, cost: 2, code: code)
        try await bind(env, slot: 1, uid: "M1", pnum: 101)

        let scanner = FakeChipScanner()
        let location = RecordingLocationProvider(fix: validFix())
        let model = makeModel(env: env, roster: members([1]), scanner: scanner, location: location)
        model.start(scanner: scanner)
        await poll { model.bindings["M1"] == 1 }

        scanner.emit(reading(code: code, uid: "CP", elapsed: 0))
        await poll { model.session?.checkpointId == 100 }
        // Дожидаемся GPS-attach (locLat заполнён).
        await poll { (try? await env.markStore.getById("mark-1"))??.locLat != nil }

        // Участник добавляется после attach — present не затёрт колоночным attachLocation.
        scanner.emit(reading(code: nil, uid: "M1", elapsed: 100))
        await poll { (try? await env.markStore.getById("mark-1"))??.present == [1] }

        let mark = try #require(try await env.markStore.getById("mark-1"))
        #expect(mark.locLat == 55.75)
        #expect(mark.locLon == 37.61)
        #expect(mark.present == [1])
        let calls = await location.callCount
        #expect(calls == 1)   // один фикс на новое взятие
    }

    // MARK: - Отказ GPS → mark без координат

    @Test func gpsRefusalYieldsMarkWithoutCoords() async throws {
        let env = try makeEnv()
        let code = kpCode(10)
        try await registerKp(env, cpId: 100, number: 5, cost: 2, code: code)

        let scanner = FakeChipScanner()
        let location = RecordingLocationProvider(fix: nil)   // нет разрешения/GPS
        let model = makeModel(env: env, roster: members([1]), scanner: scanner, location: location)
        model.start(scanner: scanner)

        scanner.emit(reading(code: code, uid: "CP", elapsed: 0))
        await poll { (try? await env.markStore.getById("mark-1")) != nil }
        // Дать attach-Task отработать (вернёт nil → no-op).
        let calls = await pollCallCount(location)
        #expect(calls == 1)
        let mark = try #require(try await env.markStore.getById("mark-1"))
        #expect(mark.locLat == nil)
    }

    private func pollCallCount(_ provider: RecordingLocationProvider) async -> Int {
        await poll { await provider.callCount >= 1 }
        return await provider.callCount
    }

    // MARK: - Гвард «команда не выбрана» (пустой ростер)

    @Test func emptyRosterRefusesWithGuard() async throws {
        let env = try makeEnv()
        let code = kpCode(11)
        try await registerKp(env, cpId: 100, number: 5, cost: 2, code: code)

        let scanner = FakeChipScanner()
        let feedback = RecordingFeedback()
        let model = makeModel(env: env, roster: [], scanner: scanner, feedback: feedback)
        model.start(scanner: scanner)

        scanner.emit(reading(code: code, uid: "CP", elapsed: 0))
        await poll { model.diagnostic == "команда не выбрана" }
        #expect(model.session == nil)
        #expect(feedback.failureCount == 1)
        // Взятие не открыто.
        #expect(try await env.markStore.getById("mark-1") == nil)
    }

    // MARK: - Автозакрытие по истечению окна (таймер)

    @Test func windowExpiryAutoCloses() async throws {
        let env = try makeEnv()
        let code = kpCode(12)
        try await registerKp(env, cpId: 100, number: 5, cost: 2, code: code)

        let scanner = FakeChipScanner()
        let elapsed = FakeElapsed(0)
        // Мелкий тик, чтобы таймер быстро заметил истечение.
        let model = makeModel(env: env, roster: members([1]), scanner: scanner, elapsed: elapsed, tickMs: 10)
        model.start(scanner: scanner)

        scanner.emit(reading(code: code, uid: "CP", elapsed: 0))
        await poll { model.session?.checkpointId == 100 }

        // Продвигаем монотонные часы за пределы окна — таймер финализирует и просит закрытие.
        await elapsed.set(SCAN_WINDOW_MS + 1_000)
        await poll { model.closeRequested }
        #expect(model.closeRequested == true)
        #expect(model.session == nil)
        #expect(model.didComplete == false)   // истечение окна — не успешное завершение (нет конфетти)
    }

    // MARK: - Быстрое автозакрытие: successHoldMs = 0 → немедленное закрытие + didComplete (этап 11)

    @Test func completionWithZeroHoldClosesImmediatelyAndDidComplete() async throws {
        let env = try makeEnv()
        let code = kpCode(25)
        try await registerKp(env, cpId: 100, number: 5, cost: 2, code: code)
        try await bind(env, slot: 1, uid: "M1", pnum: 101)

        let scanner = FakeChipScanner()
        // Нулевой hold (дефолт этапа 11) — завершение закрывает оверлей немедленно.
        let model = makeModel(env: env, roster: members([1]), scanner: scanner, successHoldMs: 0)
        model.start(scanner: scanner)
        await poll { model.bindings["M1"] == 1 }

        scanner.emit(reading(code: code, uid: "CP", elapsed: 0))
        await poll { model.session?.checkpointId == 100 }
        scanner.emit(reading(code: nil, uid: "M1", elapsed: 100))
        await poll { model.closeRequested }
        #expect(model.closeRequested == true)
        #expect(model.didComplete == true)   // успешное завершение → конфетти на «Отметках»
        #expect(model.session == nil)
    }

    // MARK: - Продовый дефолт successHoldMs (этап 11): реальный init БЕЗ параметра → немедленное закрытие

    /// Замок на продовое значение `defaultSuccessHoldMs = 0`: строим `ScanModel` через РЕАЛЬНЫЙ init,
    /// НЕ передавая `successHoldMs` (в отличие от `makeModel`, который дефолтит его на 3_600_000). Так
    /// проверяется именно продовый дефолт этапа 11, а не механизм с явно переданным нулём — откат
    /// константы к 3300 уронил бы этот тест (иначе оверлей не автозакрылся бы немедленно).
    @Test func completionUsesProductionDefaultHoldAndClosesImmediately() async throws {
        let env = try makeEnv()
        let code = kpCode(26)
        try await registerKp(env, cpId: 100, number: 5, cost: 2, code: code)
        try await bind(env, slot: 1, uid: "M1", pnum: 101)

        let scanner = FakeChipScanner()
        let elapsed = FakeElapsed()
        let ids = IdGen()
        // Реальный init БЕЗ successHoldMs — берётся продовый `defaultSuccessHoldMs` (этап 11: 0).
        let model = ScanModel(
            raceId: race, teamId: team, roster: members([1]),
            legendRepository: env.legendRepository, markStore: env.markStore,
            bindingStore: env.memberChipBindingStore,
            locationProvider: RecordingLocationProvider(fix: nil),
            feedback: RecordingFeedback(), elapsedNowMs: { await elapsed.get() },
            newMarkId: { ids.next() },
            tickMs: 3_600_000, fanfareDelayMs: 0
        )
        model.start(scanner: scanner)
        await poll { model.bindings["M1"] == 1 }

        scanner.emit(reading(code: code, uid: "CP", elapsed: 0))
        await poll { model.session?.checkpointId == 100 }
        scanner.emit(reading(code: nil, uid: "M1", elapsed: 100))
        await poll { model.closeRequested }
        #expect(model.closeRequested == true)
        #expect(model.didComplete == true)
        #expect(model.session == nil)
    }

    // MARK: - Near-deadline скан продлевает окно; таймер не финализирует его как истёкший (Finding-1)

    @Test func nearDeadlineScanExtendsWindowTimerDoesNotClose() async throws {
        let env = try makeEnv()
        let code = kpCode(24)
        try await registerKp(env, cpId: 100, number: 5, cost: 2, code: code)
        try await bind(env, slot: 1, uid: "M1", pnum: 101)

        let scanner = FakeChipScanner()
        let elapsed = FakeElapsed(0)
        // Активный таймер (мелкий тик) + ростер из 2 (взятие не завершится и не автозакроется по complete).
        let model = makeModel(env: env, roster: members([1, 2]), scanner: scanner, elapsed: elapsed, tickMs: 10)
        model.start(scanner: scanner)
        await poll { model.bindings["M1"] == 1 }

        // КП на elapsed 0 → окно от 0.
        scanner.emit(reading(code: code, uid: "CP", elapsed: 0))
        await poll { model.session?.checkpointId == 100 }

        // Участник поднят у самой границы (19_900 < 20_000 от lastScanAt=0) — окно ПРОДЛЕНО до 19_900.
        // Скан сериализован с тиками таймера (§7), поэтому применяется до любой оценки истечения.
        scanner.emit(reading(code: nil, uid: "M1", elapsed: SCAN_WINDOW_MS - 100))
        await poll { model.session?.present == [1] }
        #expect(model.session?.lastScanAt == SCAN_WINDOW_MS - 100)

        // Часы уходят за исходную границу (0+20_000), но окно теперь считается от 19_900:
        // 20_050 − 19_900 = 150 мс < 20_000 → НЕ истекло, оверлей не закрывается (near-deadline скан не потерян).
        await elapsed.set(SCAN_WINDOW_MS + 50)
        // Даём таймеру несколько циклов (tick=10мс) — он не должен финализировать/закрыть.
        try? await Task.sleep(for: .milliseconds(150))
        #expect(model.closeRequested == false)
        #expect(model.session?.present == [1])
        #expect(model.session?.checkpointId == 100)

        // Контроль живости таймера: за истинной границей (от 19_900) он всё же закрывает окно.
        await elapsed.set((SCAN_WINDOW_MS - 100) + SCAN_WINDOW_MS + 500)
        await poll { model.closeRequested }
        #expect(model.closeRequested == true)
        #expect(model.session == nil)
    }

    // MARK: - Автозакрытие по завершению (hold)

    @Test func completionAutoClosesAfterHold() async throws {
        let env = try makeEnv()
        let code = kpCode(13)
        try await registerKp(env, cpId: 100, number: 5, cost: 2, code: code)
        try await bind(env, slot: 1, uid: "M1", pnum: 101)

        let scanner = FakeChipScanner()
        // Короткий hold, чтобы завершение закрыло оверлей.
        let model = makeModel(env: env, roster: members([1]), scanner: scanner, successHoldMs: 20)
        model.start(scanner: scanner)
        await poll { model.bindings["M1"] == 1 }

        scanner.emit(reading(code: code, uid: "CP", elapsed: 0))
        await poll { model.session?.checkpointId == 100 }
        scanner.emit(reading(code: nil, uid: "M1", elapsed: 100))
        await poll { model.closeRequested }
        #expect(model.closeRequested == true)
        #expect(model.session == nil)
    }

    // MARK: - Повтор того же КП в живом окне → только перештамп окна (§3)

    @Test func sameKpRescanInLiveWindowOnlyRestampsWindow() async throws {
        let env = try makeEnv()
        let code = kpCode(21)
        try await registerKp(env, cpId: 100, number: 5, cost: 2, code: code)
        try await bind(env, slot: 1, uid: "M1", pnum: 101)

        let scanner = FakeChipScanner()
        // Ростер из 2 → взятие не завершается и оверлей не автозакрывается на повторе.
        let model = makeModel(env: env, roster: members([1, 2]), scanner: scanner)
        model.start(scanner: scanner)
        await poll { model.bindings["M1"] == 1 }

        scanner.emit(reading(code: code, uid: "CP", elapsed: 0))
        await poll { model.session?.checkpointId == 100 }
        scanner.emit(reading(code: nil, uid: "M1", elapsed: 100))
        await poll { model.session?.present == [1] }
        #expect(model.session?.lastScanAt == 100)

        // Тот же КП снова в живом окне: только перештамп окна — present сохранён, второе взятие НЕ открыто.
        scanner.emit(reading(code: code, uid: "CP", elapsed: 5_000))
        await poll { model.session?.lastScanAt == 5_000 }
        #expect(model.session?.present == [1])                        // present сохранён
        #expect(model.session?.checkpointId == 100)
        #expect(try await env.markStore.getById("mark-2") == nil)    // newMarkId не дёрнут → второго взятия нет
        let mark = try #require(try await env.markStore.getById("mark-1"))
        #expect(mark.checkpointId == 100)
    }

    // MARK: - Инкрементальное завершение многочленной команды через addMember

    @Test func incrementalMultiMemberCompletesViaAddMember() async throws {
        let env = try makeEnv()
        let code = kpCode(22)
        try await registerKp(env, cpId: 100, number: 8, cost: 4, code: code)
        try await bind(env, slot: 1, uid: "M1", pnum: 101)
        try await bind(env, slot: 2, uid: "M2", pnum: 102)

        let scanner = FakeChipScanner()
        let model = makeModel(env: env, roster: members([1, 2]), scanner: scanner)
        model.start(scanner: scanner)
        await poll { model.bindings.count == 2 }

        // КП первым (буфер пуст), затем ОБА участника после КП → оба через addMember, не буфер-дренаж.
        scanner.emit(reading(code: code, uid: "CP", elapsed: 0))
        await poll { model.session?.checkpointId == 100 }
        #expect(model.session?.present.isEmpty == true)

        scanner.emit(reading(code: nil, uid: "M1", elapsed: 100))
        await poll { model.session?.present == [1] }
        scanner.emit(reading(code: nil, uid: "M2", elapsed: 200))
        await poll { model.session?.present == [1, 2] }
        #expect(isComplete(session: model.session, rosterSize: 2))

        // Персист: инкрементальные addMember дали полный present и complete.
        await poll { (try? await env.markStore.getById("mark-1"))??.present.count == 2 }
        let mark = try #require(try await env.markStore.getById("mark-1"))
        #expect(Set(mark.present) == [1, 2])
        #expect(mark.complete == true)
    }

    // MARK: - Фанфары приходят ПОСЛЕ success с задержкой fanfareDelayMs (§10)

    @Test func fanfareLandsAfterDelayFollowingSuccess() async throws {
        let env = try makeEnv()
        let code = kpCode(23)
        try await registerKp(env, cpId: 100, number: 5, cost: 2, code: code)
        try await bind(env, slot: 1, uid: "M1", pnum: 101)

        let scanner = FakeChipScanner()
        let feedback = RecordingFeedback()
        // Ненулевая задержка фанфар — проверяем порядок «сначала success, потом фанфары».
        let model = makeModel(
            env: env, roster: members([1]), scanner: scanner, feedback: feedback, fanfareDelayMs: 300
        )
        model.start(scanner: scanner)
        await poll { model.bindings["M1"] == 1 }

        scanner.emit(reading(code: code, uid: "CP", elapsed: 0))
        await poll { model.session?.checkpointId == 100 }
        scanner.emit(reading(code: nil, uid: "M1", elapsed: 100))

        // На переходе incomplete→complete: success записан немедленно, фанфары ЕЩЁ нет (ждут 300 мс).
        await poll { isComplete(session: model.session, rosterSize: 1) }
        #expect(feedback.successCount >= 2)   // КП + завершающий участник
        #expect(feedback.fanfares == 0)       // задержка ещё не истекла

        // Фанфары приходят после задержки.
        await poll { feedback.fanfares >= 1 }
        #expect(feedback.fanfares == 1)
    }

    // MARK: - Фанфара переживает stop() (быстрое автозакрытие этапа 11)

    /// Замок на §6-идиому фанфары: при `successHoldMs = 0` успешное завершение немедленно закрывает
    /// оверлей, а его `onDisappear` зовёт `stop()` РАНЬШЕ, чем истечёт `fanfareDelayMs`. Фанфара должна
    /// доиграть, потому что её Task захватывает `feedback` (не `self`) и НЕ отменяется в `stop()`.
    /// До фикса `stop()` отменял `fanfareTask` до конца задержки — фанфара завершения не звучала.
    @Test func fanfareSurvivesImmediateStopOnCompletion() async throws {
        let env = try makeEnv()
        let code = kpCode(27)
        try await registerKp(env, cpId: 100, number: 5, cost: 2, code: code)
        try await bind(env, slot: 1, uid: "M1", pnum: 101)

        let scanner = FakeChipScanner()
        let feedback = RecordingFeedback()
        // Ненулевая задержка фанфары + нулевой hold (дефолт этапа 11) — stop() гарантированно раньше фанфары.
        let model = makeModel(
            env: env, roster: members([1]), scanner: scanner, feedback: feedback,
            fanfareDelayMs: 150, successHoldMs: 0
        )
        model.start(scanner: scanner)
        await poll { model.bindings["M1"] == 1 }

        scanner.emit(reading(code: code, uid: "CP", elapsed: 0))
        await poll { model.session?.checkpointId == 100 }
        scanner.emit(reading(code: nil, uid: "M1", elapsed: 100))

        // Завершение просит закрытие немедленно; вьюха бы дизмиссила шит и его onDisappear зовёт stop().
        await poll { model.closeRequested }
        #expect(model.didComplete == true)
        #expect(feedback.fanfares == 0)   // задержка ещё идёт в момент закрытия
        model.stop()

        // Несмотря на stop() до истечения задержки — фанфара всё равно доигрывает.
        await poll { feedback.fanfares >= 1 }
        #expect(feedback.fanfares == 1)
    }
}
