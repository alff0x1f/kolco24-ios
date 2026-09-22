//
//  MarksModelReadinessTests.swift
//  kolco24Tests
//
//  Тесты сборки чек-листа готовности в `MarksModel` — Kotlin-источника нет (iOS-only экран).
//  Чистая табличная логика статусов покрыта `ReadinessChecklistTests`; здесь проверяется ровно то,
//  чего таблица дать не может: чтение `mapUrl` из РЕАЛЬНОЙ БД (`AppDatabase.makeInMemory()`,
//  конвенция — БД не фейкаем), stale-guard при `rebind` на другую гонку, синхронный опрос устройства
//  (`refreshDeviceState`) и перечитывание файла подложки БЕЗ `rebind` (возврат с вкладки «Карта»).
//  Сюда же переехали интеграционные случаи снятой лестницы `MarksEmpty` («нет команды», «привязаны
//  не все чипы», «подавление до первой эмиссии») — переписанные на `readiness(team:members:clock:)`.
//
//  observation/one-shot чтения асинхронные — состояние ждём поллингом с таймаутом.
//

import Foundation
import GRDB
import Testing
@testable import kolco24

@MainActor
struct MarksModelReadinessTests {

    // MARK: - Фикстуры

    private func race(id: Int, mapUrl: String?) -> Race {
        Race(id: id, name: "Кольцо \(id)", slug: "k\(id)", date: "2026-09-19",
             place: "Лес", regStatus: "open", mapUrl: mapUrl)
    }

    private func team(id: Int, race: Int, name: String) -> Team {
        Team(id: id, raceId: race, teamname: name, startNumber: nil, categoryId: nil,
             ucount: 2, paidPeople: 2, startTime: 0, finishTime: 0, members: [])
    }

    private func members(_ nums: [Int]) -> [TeamMemberItem] {
        nums.map { TeamMemberItem(name: "Участник \($0)", numberInTeam: $0) }
    }

    private func binding(team: Int, num: Int, uid: String = "AA", pnum: Int) -> MemberChipBinding {
        MemberChipBinding(teamId: team, numberInTeam: num, nfcUid: uid, participantNumber: pnum)
    }

    private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now > deadline { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func item(_ items: [ReadinessItem], _ id: ReadinessItemId) -> ReadinessItem? {
        items.first { $0.id == id }
    }

    // MARK: - Доступность подложки (mapUrl из БД + файл с диска)

    @Test func mapReadiness_urlWithoutFileIsMissing() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle,
                                             mapFileExists: { _ in false })
        try await env.raceStore.insertAll([race(id: 7, mapUrl: "https://example.org/7.mbtiles")])

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.mapReadiness == .missing }

        #expect(model.mapReadiness == .missing)
        let map = item(model.readiness(team: nil, members: [], clock: .ok), .map)
        #expect(map?.status == .warning)
        #expect(map?.action == .openMap)
    }

    @Test func mapReadiness_urlWithFileIsReady() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle,
                                             mapFileExists: { $0 == 7 })
        try await env.raceStore.insertAll([race(id: 7, mapUrl: "https://example.org/7.mbtiles")])

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.mapReadiness == .ready }

        #expect(model.mapReadiness == .ready)
        #expect(item(model.readiness(team: nil, members: [], clock: .ok), .map)?.status == .done)
    }

    /// Гонка без подложки: пункт карты не просто `warning`, а отсутствует в массиве — иначе чек-лист
    /// был бы вечно неполным там, где скачивать нечего.
    @Test func mapReadiness_raceWithoutUrlHidesItem() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle,
                                             mapFileExists: { _ in true })
        try await env.raceStore.insertAll([
            race(id: 7, mapUrl: nil),
            race(id: 8, mapUrl: "https://example.org/8.mbtiles"),
        ])

        let model = MarksModel(env: env)
        // Положительный контроль: сначала убеждаемся, что one-shot чтение вообще отрабатывает —
        // иначе «нет пункта» совпало бы с начальным значением `.notApplicable` и тест был бы пустым.
        model.rebind(teamId: 42, raceId: 8)
        await waitUntil { model.mapReadiness == .ready }
        #expect(model.mapReadiness == .ready)

        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.marksLoading == false }
        model.refreshDeviceState()

        #expect(model.mapReadiness == .notApplicable)
        #expect(item(model.readiness(team: nil, members: [], clock: .ok), .map) == nil)
    }

    /// Пустая строка в `races.map_url` (правдоподобное серверное значение) — то же, что её отсутствие.
    @Test func mapReadiness_emptyUrlHidesItem() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle,
                                             mapFileExists: { _ in true })
        try await env.raceStore.insertAll([race(id: 7, mapUrl: "")])

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.marksLoading == false }
        model.refreshDeviceState()

        #expect(model.mapReadiness == .notApplicable)
    }

    /// `mapUrl` может появиться в БД уже во время просмотра чек-листа (синк пишет `races.map_url`
    /// впервые), а `rebind` на той же паре рано выходит — пункт обязан появиться от опроса.
    @Test func refreshDeviceState_picksUpMapUrlThatArrivesLater() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle,
                                             mapFileExists: { _ in false })
        try await env.raceStore.insertAll([race(id: 7, mapUrl: nil)])

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.marksLoading == false }
        #expect(model.mapReadiness == .notApplicable)

        // Синк дописал подложку гонке, на которую мы уже привязаны.
        try await env.raceStore.insertAll([race(id: 7, mapUrl: "https://example.org/7.mbtiles")])
        model.rebind(teamId: 42, raceId: 7)   // ранний выход — сам по себе ничего не перечитает
        await waitUntil {
            model.refreshDeviceState()
            return model.mapReadiness == .missing
        }
        #expect(model.mapReadiness == .missing)
        #expect(item(model.readiness(team: nil, members: [], clock: .ok), .map)?.action == .openMap)
    }

    // MARK: - Stale-guard: подложка прежней гонки не доживает до эмиссии новой

    @Test func rebind_resetsMapReadinessSynchronously() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle,
                                             mapFileExists: { _ in true })
        try await env.raceStore.insertAll([
            race(id: 7, mapUrl: "https://example.org/7.mbtiles"),
            race(id: 8, mapUrl: "https://example.org/8.mbtiles"),
        ])

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.mapReadiness == .ready }

        // Синхронно после rebind на другую гонку — сброс, до чтения её `mapUrl` из БД.
        model.rebind(teamId: 43, raceId: 8)
        #expect(model.mapReadiness == .notApplicable)
        #expect(item(model.readiness(team: nil, members: [], clock: .ok), .map) == nil)

        // Эмиссия новой гонки приходит позже и возвращает пункт.
        await waitUntil { model.mapReadiness == .ready }
        #expect(model.mapReadiness == .ready)
    }

    // MARK: - Опрос устройства

    /// Подменённые замыкания `env` попадают в опубликованные свойства, а те — в пункты чек-листа.
    @Test func refreshDeviceState_pollsEnvClosures() async throws {
        let env = try AppEnvironment.inMemory(
            transport: FakeTransport().handle,
            isReducedAccuracy: { true },
            locationAuthorization: { .denied },
            isLowPowerMode: { true }
        )
        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        model.refreshDeviceState()

        #expect(model.locationAuth == .denied)
        #expect(model.isReducedAccuracy == true)
        #expect(model.lowPowerMode == true)

        let items = model.readiness(team: team(id: 42, race: 7, name: "Ф-мажор"),
                                    members: members([1]), clock: .noSync)
        #expect(item(items, .location)?.status == .warning)
        #expect(item(items, .location)?.action == .openSettings)
        #expect(item(items, .power)?.status == .warning)
        #expect(item(items, .clock)?.status == .warning)
        #expect(item(items, .team)?.status == .done)
        #expect(item(items, .team)?.detail == "Ф-мажор")
        // Ни одного чипа не привязано — blocked.
        #expect(item(items, .chips)?.status == .blocked)
    }

    /// Возврат с вкладки «Карта» не меняет `scenePhase` и не перезапускает `rebind` (та же пара
    /// `(teamId, raceId)` — ранний выход), поэтому файл перечитывается именно в `refreshDeviceState`.
    @Test func refreshDeviceState_rereadsMapFileWithoutRebind() async throws {
        let exists = MutableFlag()
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle,
                                             mapFileExists: { _ in exists.value })
        try await env.raceStore.insertAll([race(id: 7, mapUrl: "https://example.org/7.mbtiles")])

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.mapReadiness == .missing }
        #expect(model.mapReadiness == .missing)

        exists.value = true
        model.rebind(teamId: 42, raceId: 7)   // ранний выход — состояние не меняется
        #expect(model.mapReadiness == .missing)

        model.refreshDeviceState()
        #expect(model.mapReadiness == .ready)
    }

    // MARK: - Команда и привязки (интеграционные случаи снятой лестницы `MarksEmpty`)

    /// Нет команды: загрузки нет вовсе, а `team` и `chips` — оба `blocked` (без команды отметка
    /// физически не сработает). У `chips` при этом нет действия — сначала нужно выбрать команду.
    @Test func readiness_noTeamBlocksTeamAndChips() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle)
        let model = MarksModel(env: env)

        model.rebind(teamId: nil, raceId: nil)
        model.refreshDeviceState()
        #expect(model.marksLoading == false)
        // Без команды грузить нечего — карточка показывается сразу после первого опроса устройства.
        #expect(model.readinessCard(team: nil, members: [], clock: .ok) != nil)

        let items = model.readiness(team: nil, members: [], clock: .ok)
        #expect(item(items, .team)?.status == .blocked)
        #expect(item(items, .team)?.action == .chooseTeam)
        #expect(item(items, .chips)?.status == .blocked)
        #expect(item(items, .chips)?.detail == "Сначала выберите команду")
        #expect(item(items, .chips)?.action == nil)
    }

    /// Привязки приезжают из РЕАЛЬНОЙ БД через observation: 1 из 2 → `blocked` с «1 из 2», после
    /// второй привязки → `done`. Пустой ростер, наоборот, `blocked` — сканировать всё равно нельзя.
    @Test func readiness_unboundChipsBlockUntilAllBound() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle)
        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 1, pnum: 100))

        let model = MarksModel(env: env)
        let roster = members([1, 2])
        model.rebind(teamId: 5, raceId: 7)
        await waitUntil { model.bindings.count == 1 && model.marksLoading == false }

        let squad = team(id: 5, race: 7, name: "Ф-мажор")
        #expect(model.boundCount(members: roster) == 1)
        var chips = item(model.readiness(team: squad, members: roster, clock: .ok), .chips)
        #expect(chips?.status == .blocked)
        #expect(chips?.detail == "1 из 2")
        #expect(chips?.action == .bindChips)

        try await env.memberChipBindingStore.upsert(binding(team: 5, num: 2, uid: "BB", pnum: 200))
        await waitUntil { model.boundCount(members: roster) == 2 }

        chips = item(model.readiness(team: squad, members: roster, clock: .ok), .chips)
        #expect(chips?.status == .done)
        #expect(chips?.detail == "2 из 2")
        // Пустой ростер блокирует: скан отбивается при пустом составе («команда не выбрана»).
        #expect(item(model.readiness(team: squad, members: [], clock: .ok), .chips)?.status == .blocked)
    }

    // MARK: - Подавление до первой эмиссии (гейт readinessCardVisible)

    /// Лестницу гасил её собственный флаг `loading`; теперь то же решение принимает шов вьюхи
    /// `readinessCard(...)` — `nil`, пока не приехал каждый источник карточки (взятия, привязки,
    /// КП гонки, первый опрос устройства). Иначе чек-лист моргнул бы на холодном старте ложным
    /// «чипы не привязаны» (снимок привязок ещё пуст).
    @Test func readinessCard_nilUntilFirstEmission() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle)
        try await env.memberChipBindingStore.upsert(binding(team: 42, num: 1, pnum: 100))

        let model = MarksModel(env: env)
        let squadLoading = team(id: 42, race: 7, name: "Ф-мажор")
        model.rebind(teamId: 42, raceId: 7)
        model.refreshDeviceState()
        // Синхронно после rebind: команда есть, observation ещё не эмитил — рисовать нечего.
        #expect(model.marksLoading == true)
        #expect(model.bindings.isEmpty)
        #expect(model.readinessCard(team: squadLoading, members: members([1]), clock: .ok) == nil)

        await waitUntil {
            model.marksLoading == false && model.bindings.count == 1
                && model.checkpointsLoading == false && model.mapUrlResolved
        }
        // Все источники приехали — шов отдаёт готовый массив.
        // Статусы самих строк после снятия гейта проверяет `readiness_unboundChipsBlockUntilAllBound`.
        #expect(model.readinessCard(team: squadLoading, members: members([1]), clock: .ok) != nil)
    }

    /// Легенда в чек-листе считается по КП гонки из РЕАЛЬНОЙ БД (`checkpoints.count`), а не по
    /// взятиям/привязкам: без этой проводки строка «Легенда» врала бы на устройстве.
    @Test func readiness_legendCountsCheckpointsOfRace() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle)
        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.marksLoading == false }

        // Пусто — предупреждение с CTA «обновить».
        var legend = item(model.readiness(team: nil, members: [], clock: .ok), .legend)
        #expect(legend?.status == .warning)
        #expect(legend?.action == .refresh)

        try await env.checkpointStore.insertCheckpoints([
            Checkpoint(id: 1, raceId: 7, number: 7, cost: 4, type: "cp", description: nil, locked: false),
            Checkpoint(id: 2, raceId: 7, number: 12, cost: 6, type: "cp", description: nil, locked: false),
        ])
        await waitUntil { model.checkpoints.count == 2 }

        legend = item(model.readiness(team: nil, members: [], clock: .ok), .legend)
        #expect(legend?.status == .done)
        #expect(legend?.detail == "2 КП")
    }

    /// `.requestLocation` — единственное действие строки, идущее через модель: проверяем сам форвард
    /// в `env.requestLocationAuthorization` (иначе пункт `.notDetermined` был бы мёртвым тапом).
    @Test func requestLocationAccess_forwardsToEnvClosure() async throws {
        let asked = MutableFlag()
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle,
                                             requestLocationAuthorization: { asked.value = true })
        let model = MarksModel(env: env)

        #expect(asked.value == false)
        model.requestLocationAccess()
        #expect(asked.value == true)
    }

    /// Гейт карточки держит ВСЕ источники, а не только взятия: `bindingsLoading`/`checkpointsLoading`
    /// взводятся синхронно в `rebind` и снимаются своими observation'ами. Кадр «взятия уже пришли,
    /// привязки ещё нет» обязан остаться пустым — иначе полностью привязанная команда моргнёт
    /// красным «Чипы привязаны не всем · 0 из N».
    @Test func readinessCard_nilUntilBindingsAndCheckpointsEmit() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle)
        try await env.memberChipBindingStore.upsert(binding(team: 42, num: 1, pnum: 100))

        let model = MarksModel(env: env)
        let squad = team(id: 42, race: 7, name: "Ф-мажор")
        model.rebind(teamId: 42, raceId: 7)
        model.refreshDeviceState()
        #expect(model.bindingsLoading == true)
        #expect(model.checkpointsLoading == true)

        // Симулируем реальный порядок «взятия эмитировали первыми»: взятий у команды нет, флаг
        // взятий снят, а снимок привязок ещё пуст — карточки быть не должно.
        await waitUntil { model.marksLoading == false }
        #expect(model.marksLoading == false)
        if model.bindingsLoading {
            #expect(model.bindings.isEmpty)
            #expect(model.readinessCard(team: squad, members: members([1]), clock: .ok) == nil)
        }

        // Чистый гейт того же кадра — без гонок планировщика.
        #expect(readinessCardVisible(marksLoading: false, bindingsLoading: true,
                                     checkpointsLoading: false, deviceStatePolled: true,
                                     mapUrlResolved: true) == false)

        await waitUntil {
            model.bindingsLoading == false && model.checkpointsLoading == false && model.mapUrlResolved
        }
        #expect(model.readinessCard(team: squad, members: members([1]), clock: .ok) != nil)
        // И к этому моменту привязка уже в снимке — красного «0 из 1» не было.
        let items = model.readinessCard(team: squad, members: members([1]), clock: .ok) ?? []
        #expect(item(items, .chips)?.status == .done)
    }

    /// Пустая строка в `races.map_url` — не `nil`, и значение-гард «перечитывать, пока `mapUrl == nil`»
    /// выключал бы опрос навсегда: пункт карты не появился бы даже после того, как синк записал
    /// настоящий URL.
    @Test func refreshDeviceState_picksUpMapUrlAfterEmptyString() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle,
                                             mapFileExists: { _ in false })
        try await env.raceStore.insertAll([race(id: 7, mapUrl: "")])

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.marksLoading == false }
        model.refreshDeviceState()
        #expect(model.mapReadiness == .notApplicable)

        try await env.raceStore.insertAll([race(id: 7, mapUrl: "https://example.org/7.mbtiles")])
        // Опрашиваем до победного: чтение `mapUrl` асинхронное, и опрос, попавший на уже летящее
        // чтение, пропускается по гарду — вьюха точно так же опрашивает повторно.
        await waitUntil {
            model.refreshDeviceState()
            return model.mapReadiness == .missing
        }
        #expect(model.mapReadiness == .missing)
    }

    /// Обратная сторона: подложку отозвали на сервере — пункт обязан исчезнуть, иначе чек-лист
    /// утверждал бы «Карта скачана» там, где `MapModel` уже показывает «карты нет».
    @Test func refreshDeviceState_dropsMapItemWhenUrlCleared() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle,
                                             mapFileExists: { _ in true })
        try await env.raceStore.insertAll([race(id: 7, mapUrl: "https://example.org/7.mbtiles")])

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        await waitUntil { model.mapReadiness == .ready }

        try await env.raceStore.insertAll([race(id: 7, mapUrl: "")])
        await waitUntil {
            model.refreshDeviceState()
            return model.mapReadiness == .notApplicable
        }
        #expect(model.mapReadiness == .notApplicable)
        #expect(item(model.readiness(team: nil, members: [], clock: .ok), .map) == nil)
    }

    // MARK: - Гейт: чтение `mapUrl` — пятый, не-observation источник

    /// Чтение `races.map_url` асинхронно и НЕ входит ни в один observation: без собственного сигнала
    /// гейт открывался бы раньше него и карточка успевала показать ложное «Всё готово к старту»,
    /// а затем развернуться в семь строк с «Карта не скачана».
    @Test func readinessCard_waitsForMapUrlRead() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle,
                                              mapFileExists: { _ in false })
        try await env.raceStore.insertAll([race(id: 7, mapUrl: "https://example.org/7.mbtiles")])

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        model.refreshDeviceState()
        // Синхронно после rebind подложка ещё не прочитана — карточку рисовать нельзя.
        #expect(model.mapUrlResolved == false)
        #expect(model.readinessCard(team: nil, members: [], clock: .ok) == nil)

        await waitUntil { model.mapUrlResolved }
        #expect(model.mapUrlResolved == true)
        // К моменту открытия гейта пункт карты уже на месте — списка из 6 строк никто не увидел.
        let items = model.readinessCard(team: nil, members: [], clock: .ok) ?? []
        #expect(items.isEmpty == false)
        #expect(item(items, .map)?.status == .warning)
    }

    /// Обратная опасность того же сигнала: у гонки честно нет подложки, чтение возвращает `nil` и
    /// уходит по раннему выходу «строка не изменилась». Флаг обязан взводиться и там — иначе гейт
    /// не открылся бы НИКОГДА и экран остался бы пустым.
    @Test func readinessCard_opensGateWhenRaceHasNoMapUrl() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle,
                                              mapFileExists: { _ in false })
        try await env.raceStore.insertAll([race(id: 7, mapUrl: nil)])

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        model.refreshDeviceState()
        #expect(model.mapUrlResolved == false)

        await waitUntil { model.mapUrlResolved }
        #expect(model.mapUrlResolved == true)
        let items = model.readinessCard(team: nil, members: [], clock: .ok) ?? []
        #expect(items.isEmpty == false)
        #expect(item(items, .map) == nil)
    }

    /// Гонки нет вовсе (`raceId == nil`) — читать нечего, сигнал взводится синхронно в `rebind`.
    @Test func readinessCard_mapSignalResolvedSynchronouslyWithoutRace() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle)
        let model = MarksModel(env: env)

        model.rebind(teamId: nil, raceId: nil)
        #expect(model.mapUrlResolved == true)
    }

    // MARK: - Умерший observation не запирает гейт навсегда

    /// Ошибка-значение, а не крах: если поток наблюдения бросит (сбой БД/схемы), флаг загрузки обязан
    /// сняться в `catch`. Иначе гейт карточки закрыт до перезапуска приложения — ветка «нет взятий»
    /// показывала бы пустоту без единого CTA. Ломаем БД по-настоящему: роняем таблицу привязок.
    @Test func readinessCard_survivesFailedObservation() async throws {
        let env = try AppEnvironment.inMemory(transport: FakeTransport().handle)
        try await env.database.writer.write { db in
            try db.execute(sql: "DROP TABLE member_chip_bindings")
        }

        let model = MarksModel(env: env)
        model.rebind(teamId: 42, raceId: 7)
        model.refreshDeviceState()
        #expect(model.bindingsLoading == true)

        // Поток привязок бросает на первой же выборке — флаг снимается, гейт открывается.
        await waitUntil { model.bindingsLoading == false }
        #expect(model.bindingsLoading == false)
        #expect(model.bindings.isEmpty)

        await waitUntil { model.readinessCard(team: nil, members: [], clock: .ok) != nil }
        #expect(model.readinessCard(team: nil, members: [], clock: .ok) != nil)
    }
}

/// Потокобезопасный флаг для `@Sendable`-замыкания `mapFileExists`.
private final class MutableFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); defer { lock.unlock() }; storage = newValue }
    }
}
