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

    @Test func emptyRoster_countsAsDone() {
        let items = readinessItems(input(memberCount: 0, boundCount: 0))

        #expect(item(items, .chips)?.status == .done)
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
        #expect(power?.action == .openSettings)
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
        let worst = readinessItems(input(
            hasTeam: false,
            teamTitle: "",
            memberCount: 0,
            boundCount: 0,
            locationAuthorization: .denied,
            checkpointCount: 0,
            map: .missing,
            clock: .noSync,
            lowPowerMode: true
        ))

        #expect(worst.map(\.id) == [.team, .chips, .location, .legend, .map, .clock, .power])
    }

    @Test func blockedOnlyForTeamAndChips() {
        let worst = readinessItems(input(
            hasTeam: false,
            teamTitle: "",
            memberCount: 0,
            boundCount: 0,
            locationAuthorization: .denied,
            checkpointCount: 0,
            map: .missing,
            clock: .noSync,
            lowPowerMode: true
        ))

        #expect(worst.filter { $0.status == .blocked }.map(\.id) == [.team, .chips])
    }
}
