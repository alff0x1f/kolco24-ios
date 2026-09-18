//
//  ReadinessChecklistTests.swift
//  kolco24Tests
//
//  Табличные тесты чистого ядра чек-листа готовности (`Core/Readiness/ReadinessChecklist.swift`).
//  Kotlin-источника нет — экран iOS-only. Сюда же переехало покрытие удалённой лестницы
//  `MarksEmpty` («нет команды», «не все чипы привязаны», «готов»).
//

import Foundation
import Testing
@testable import kolco24

struct ReadinessChecklistTests {

    private func input(
        hasTeam: Bool = true,
        teamTitle: String = "Ф-мажор",
        memberCount: Int = 4,
        boundCount: Int = 4,
        locationAuthorization: LocationAuthorization = .granted,
        isReducedAccuracy: Bool = false,
        checkpointCount: Int = 42,
        map: MapReadiness = .ready,
        clock: ClockStatus = .ok,
        lowPowerMode: Bool = false
    ) -> ReadinessInput {
        ReadinessInput(
            hasTeam: hasTeam,
            teamTitle: teamTitle,
            memberCount: memberCount,
            boundCount: boundCount,
            locationAuthorization: locationAuthorization,
            isReducedAccuracy: isReducedAccuracy,
            checkpointCount: checkpointCount,
            map: map,
            clock: clock,
            lowPowerMode: lowPowerMode
        )
    }

    /// «Всё плохо»: каждый пункт в худшем из возможных для него статусов и ни один не скрыт —
    /// общая фикстура для проверок порядка, множества `blocked` и худшего статуса сводки.
    private var worstInput: ReadinessInput {
        input(
            hasTeam: false,
            teamTitle: "",
            memberCount: 0,
            boundCount: 0,
            locationAuthorization: .denied,
            checkpointCount: 0,
            map: .missing,
            clock: .noSync,
            lowPowerMode: true
        )
    }

    private func item(_ items: [ReadinessItem], _ id: ReadinessItemId) -> ReadinessItem? {
        items.first { $0.id == id }
    }

    // MARK: - Команда и чипы

    @Test func noTeam_blocksTeamAndChips() {
        let items = readinessItems(input(hasTeam: false, teamTitle: "", memberCount: 0, boundCount: 0))

        #expect(item(items, .team)?.status == .blocked)
        #expect(item(items, .team)?.action == .chooseTeam)
        #expect(item(items, .chips)?.status == .blocked)
        #expect(item(items, .chips)?.detail == "Сначала выберите команду")
        // Действия у `chips` нет намеренно: привязка до выбора команды — тупик, CTA несёт строка `team`.
        #expect(item(items, .chips)?.action == nil)
    }

    @Test func teamSelected_showsTeamTitleAsDetail() {
        let items = readinessItems(input())

        #expect(item(items, .team)?.status == .done)
        #expect(item(items, .team)?.detail == "Ф-мажор")
    }

    @Test func partiallyBoundChips_isBlockedWithCounter() {
        let items = readinessItems(input(memberCount: 4, boundCount: 3))

        let chips = item(items, .chips)
        #expect(chips?.status == .blocked)
        #expect(chips?.detail == "3 из 4")
        #expect(chips?.action == .bindChips)
    }

    @Test func allChipsBound_isDone() {
        let items = readinessItems(input(memberCount: 4, boundCount: 4))

        #expect(item(items, .chips)?.status == .done)
        #expect(item(items, .chips)?.detail == "4 из 4")
    }

    /// Пустой ростер — НЕ «готово»: `ScanModel.process` отбивает скан при пустом составе, поэтому
    /// зелёная галочка обещала бы невозможное. Блокируем с CTA «обновить данные».
    @Test func emptyRoster_blocksChipsWithRefresh() {
        let items = readinessItems(input(memberCount: 0, boundCount: 0))

        let chips = item(items, .chips)
        #expect(chips?.status == .blocked)
        #expect(chips?.title == "Состав команды не загружен")
        #expect(chips?.action == .refresh)
    }

    /// Привязок больше, чем слотов ростера (устаревшая запись удалённого участника) — всё равно `done`.
    @Test func boundCountAboveMemberCount_isDone() {
        #expect(item(readinessItems(input(memberCount: 2, boundCount: 3)), .chips)?.status == .done)
    }

    // MARK: - Геолокация

    @Test func grantedFullAccuracy_isDone() {
        let items = readinessItems(input(locationAuthorization: .granted, isReducedAccuracy: false))

        let location = item(items, .location)
        #expect(location?.status == .done)
        #expect(location?.action == nil)
    }

    @Test func notDetermined_asksForPermission() {
        let items = readinessItems(input(locationAuthorization: .notDetermined))

        let location = item(items, .location)
        #expect(location?.status == .warning)
        #expect(location?.action == .requestLocation)
    }

    @Test func denied_sendsToSettings() {
        let items = readinessItems(input(locationAuthorization: .denied))

        let location = item(items, .location)
        #expect(location?.status == .warning)
        #expect(location?.action == .openSettings)
    }

    @Test func reducedAccuracy_sendsToSettings() {
        let items = readinessItems(input(locationAuthorization: .granted, isReducedAccuracy: true))

        let location = item(items, .location)
        #expect(location?.status == .warning)
        #expect(location?.action == .openSettings)
    }

    // MARK: - Скрытие пунктов

    @Test func noMapUrl_hidesMapItem() {
        let items = readinessItems(input(map: .notApplicable))

        #expect(item(items, .map) == nil)
    }

    @Test func missingMap_isWarningWithOpenMap() {
        let items = readinessItems(input(map: .missing))

        let map = item(items, .map)
        #expect(map?.status == .warning)
        #expect(map?.action == .openMap)
    }

    @Test func lowPowerModeOff_hidesPowerItem() {
        let items = readinessItems(input(lowPowerMode: false))

        #expect(item(items, .power) == nil)
    }

    @Test func lowPowerModeOn_showsWarning() {
        let items = readinessItems(input(lowPowerMode: true))

        let power = item(items, .power)
        #expect(power?.status == .warning)
        // Действия нет: `app-settings:` ведёт на страницу приложения, а Low Power Mode живёт в
        // Настройках → Аккумулятор, публичного URL туда нет — стрелка была бы тупиком.
        #expect(power?.action == nil)
        #expect(power?.detail.contains("Аккумулятор") == true)
    }

    // MARK: - Часы и легенда

    @Test func clockOk_isDone() {
        #expect(item(readinessItems(input(clock: .ok)), .clock)?.status == .done)
    }

    @Test func clockNoSyncAndSkewed_areWarningsWithDifferentDetails() {
        let noSync = item(readinessItems(input(clock: .noSync)), .clock)
        let skewed = item(readinessItems(input(clock: .skewed(skewMs: 120_000))), .clock)

        #expect(noSync?.status == .warning)
        #expect(skewed?.status == .warning)
        #expect(noSync?.detail != skewed?.detail)
        #expect(skewed?.detail.contains("2 мин") == true)
    }

    @Test func emptyLegend_isWarningWithRefresh() {
        let items = readinessItems(input(checkpointCount: 0))

        let legend = item(items, .legend)
        #expect(legend?.status == .warning)
        #expect(legend?.action == .refresh)
    }

    // MARK: - Состав и порядок массива

    @Test func allSignalsGood_lowPowerOn_hasSevenItems() {
        let items = readinessItems(input(map: .ready, lowPowerMode: true))

        #expect(items.count == 7)
        #expect(items.map(\.id) == [.team, .chips, .location, .legend, .map, .clock, .power])
        #expect(items.filter { $0.status != .done }.map(\.id) == [.power])
    }

    @Test func noMapNoLowPower_hasFiveDoneItems() {
        let items = readinessItems(input(map: .notApplicable, lowPowerMode: false))

        #expect(items.count == 5)
        #expect(items.map(\.id) == [.team, .chips, .location, .legend, .clock])
        #expect(items.allSatisfy { $0.status == .done })
    }

    @Test func orderIsStableRegardlessOfStatuses() {
        let worst = readinessItems(worstInput)

        #expect(worst.map(\.id) == [.team, .chips, .location, .legend, .map, .clock, .power])
    }

    @Test func blockedOnlyForTeamAndChips() {
        let worst = readinessItems(worstInput)

        #expect(worst.filter { $0.status == .blocked }.map(\.id) == [.team, .chips])
    }

    // MARK: - Сводка шапки (`readinessSummary`)

    @Test func summary_countsDoneAgainstArrayLength() {
        let summary = readinessSummary(readinessItems(input(map: .ready, lowPowerMode: true)))

        #expect(summary.total == 7)          // знаменатель — длина массива, не константа 7
        #expect(summary.done == 6)           // всё, кроме энергосбережения
        #expect(summary.allDone == false)
    }

    @Test func summary_worstStatusPrefersBlockedOverWarning() {
        let blocked = readinessSummary(readinessItems(worstInput))
        let warning = readinessSummary(readinessItems(input(checkpointCount: 0)))
        let good = readinessSummary(readinessItems(input(map: .notApplicable)))

        #expect(blocked.worst == .blocked)
        #expect(warning.worst == .warning)
        #expect(good.worst == .done)
    }

    @Test func summary_allDoneCollapsesOnlyWhenEveryItemIsDone() {
        #expect(readinessSummary(readinessItems(input(map: .notApplicable))).allDone == true)
        #expect(readinessSummary(readinessItems(input(map: .missing))).allDone == false)
        // Пустой массив (в UI недостижим) не считается готовностью — сворачивать нечего.
        #expect(readinessSummary([]).allDone == false)
        #expect(readinessSummary([]).worst == .done)
    }

    // MARK: - Гейт первой отрисовки

    /// Карточку прячет ЛЮБОЙ не приехавший источник по отдельности — в частности снимок привязок,
    /// даже когда взятия уже эмитировали (гейт только по взятиям давал бы красное «0 из N»).
    @Test func cardVisible_hiddenUntilEverySourceArrived() {
        #expect(readinessCardVisible(marksLoading: false, bindingsLoading: false,
                                     checkpointsLoading: false, deviceStatePolled: true,
                                     mapUrlResolved: true) == true)
        // Взятия пришли, привязки — ещё нет: именно этот кадр мигал красным.
        #expect(readinessCardVisible(marksLoading: false, bindingsLoading: true,
                                     checkpointsLoading: false, deviceStatePolled: true,
                                     mapUrlResolved: true) == false)
        #expect(readinessCardVisible(marksLoading: true, bindingsLoading: false,
                                     checkpointsLoading: false, deviceStatePolled: true,
                                     mapUrlResolved: true) == false)
        #expect(readinessCardVisible(marksLoading: false, bindingsLoading: false,
                                     checkpointsLoading: true, deviceStatePolled: true,
                                     mapUrlResolved: true) == false)
        // До первого опроса устройства поля держат дефолты — зелёная «Геолокация разрешена» была бы ложью.
        #expect(readinessCardVisible(marksLoading: false, bindingsLoading: false,
                                     checkpointsLoading: false, deviceStatePolled: false,
                                     mapUrlResolved: true) == false)
        // `mapUrl` ещё не прочитан: без этого сигнала карточка сворачивалась в зелёное «Всё готово к
        // старту» и через миг разворачивалась строкой «Карта не скачана».
        #expect(readinessCardVisible(marksLoading: false, bindingsLoading: false,
                                     checkpointsLoading: false, deviceStatePolled: true,
                                     mapUrlResolved: false) == false)
    }
}
