//
//  TeamPickerLogicTests.swift
//  kolco24Tests
//
//  Зеркало `ui/teampicker/TeamPickerLogicTest.kt` (39 кейсов) 1:1.
//  `nearestRaceId` живёт в `Core/Util/RaceDates.swift`, но его кейсы в Kotlin
//  входят в этот же сьют, поэтому зеркалятся здесь же.
//

import Testing
@testable import kolco24

struct TeamPickerLogicTests {

    private func race(
        id: Int = 1,
        date: String = "2026-06-13",
        dateEnd: String? = nil,
        regStatus: String = "open"
    ) -> Race {
        Race(
            id: id,
            name: "Гонка \(id)",
            slug: "race-\(id)",
            date: date,
            dateEnd: dateEnd,
            place: "Лес",
            regStatus: regStatus
        )
    }

    private func team(
        id: Int = 1,
        teamname: String = "Лоси",
        startNumber: String? = "201"
    ) -> Team {
        Team(
            id: id,
            raceId: 1,
            teamname: teamname,
            startNumber: startNumber,
            categoryId: 1,
            ucount: 2,
            paidPeople: 2.0,
            startTime: 0,
            finishTime: 0,
            members: []
        )
    }

    private func category(shortName: String = "Муж", name: String = "Мужская") -> Category {
        Category(id: 1, raceId: 1, code: "M", shortName: shortName, name: name, sortOrder: 0)
    }

    // --- raceStatusPill ---

    @Test func statusFinishedWhenEndBeforeToday() {
        let r = race(date: "2026-06-10", dateEnd: "2026-06-12", regStatus: "open")
        #expect(raceStatusPill(r, today: "2026-06-13") == .finished)
    }

    @Test func statusTodayIsNotFinished() {
        let r = race(date: "2026-06-13", dateEnd: "2026-06-13", regStatus: "open")
        #expect(raceStatusPill(r, today: "2026-06-13") == .registration)
    }

    @Test func statusTomorrowUsesRegStatus() {
        let r = race(date: "2026-06-14", regStatus: "upcoming")
        #expect(raceStatusPill(r, today: "2026-06-13") == .upcoming)
    }

    @Test func statusSoldOutHasNoBadge() {
        let r = race(date: "2026-06-20", regStatus: "sold_out")
        #expect(raceStatusPill(r, today: "2026-06-13") == .upcoming)
    }

    @Test func statusUnknownRegStatusFallsBackToUpcoming() {
        let r = race(date: "2026-06-20", regStatus: "something_new")
        #expect(raceStatusPill(r, today: "2026-06-13") == .upcoming)
    }

    @Test func statusUsesDateWhenDateEndNull() {
        let r = race(date: "2026-06-12", dateEnd: nil, regStatus: "open")
        #expect(raceStatusPill(r, today: "2026-06-13") == .finished)
    }

    // --- splitRaces ---

    @Test func splitPartitionsAndKeepsOrder() {
        let past = race(id: 1, date: "2026-06-01")
        let today = race(id: 2, date: "2026-06-13")
        let future = race(id: 3, date: "2026-06-20")
        let result = splitRaces([future, today, past], today: "2026-06-13")

        #expect(result.current.map { $0.id } == [3, 2])
        #expect(result.archive.map { $0.id } == [1])
    }

    @Test func splitUsesDateEndFallback() {
        let multiDay = race(id: 1, date: "2026-06-10", dateEnd: "2026-06-15")
        let result = splitRaces([multiDay], today: "2026-06-13")
        #expect(result.current.map { $0.id } == [1])
        #expect(result.archive.isEmpty)
    }

    @Test func splitEmpty() {
        let result = splitRaces([], today: "2026-06-13")
        #expect(result.current.isEmpty)
        #expect(result.archive.isEmpty)
    }

    // --- nearestRaceId ---

    @Test func nearestPicksEarliestStartDateAmongCurrentRaces() {
        let ongoing = race(id: 1, date: "2026-06-10", dateEnd: "2026-06-20")
        let upcoming = race(id: 2, date: "2026-06-18")
        #expect(nearestRaceId([upcoming, ongoing], today: "2026-06-13") == 1)
    }

    @Test func nearestPicksEarliestStartAmongOverlappingOngoing() {
        let earlierStart = race(id: 1, date: "2026-06-10", dateEnd: "2026-06-20")
        let laterStart = race(id: 2, date: "2026-06-12", dateEnd: "2026-06-18")
        #expect(nearestRaceId([laterStart, earlierStart], today: "2026-06-13") == 1)
    }

    @Test func nearestPicksSoonestFutureStart() {
        let soon = race(id: 1, date: "2026-06-15")
        let later = race(id: 2, date: "2026-06-20")
        let latest = race(id: 3, date: "2026-07-01")
        #expect(nearestRaceId([latest, later, soon], today: "2026-06-13") == 1)
    }

    @Test func nearestIncludesRaceEndingToday() {
        let endingToday = race(id: 1, date: "2026-06-13", dateEnd: "2026-06-13")
        #expect(nearestRaceId([endingToday], today: "2026-06-13") == 1)
    }

    @Test func nearestNullWhenAllArchived() {
        let past1 = race(id: 1, date: "2026-06-01", dateEnd: "2026-06-02")
        let past2 = race(id: 2, date: "2026-05-10")
        #expect(nearestRaceId([past1, past2], today: "2026-06-13") == nil)
    }

    @Test func nearestNullWhenEmpty() {
        #expect(nearestRaceId([], today: "2026-06-13") == nil)
    }

    @Test func nearestSameStartDateDoesNotCrash() {
        let a = race(id: 1, date: "2026-06-15")
        let b = race(id: 2, date: "2026-06-15")
        #expect(nearestRaceId([a, b], today: "2026-06-13") != nil)
        #expect(nearestRaceId([b, a], today: "2026-06-13") != nil)
    }

    // --- filterTeams ---

    @Test func filterByName() {
        let teams = [team(id: 1, teamname: "Лоси"), team(id: 2, teamname: "Волки")]
        #expect(filterTeams(teams, query: "лос").map { $0.id } == [1])
    }

    @Test func filterByStartNumber() {
        let teams = [team(id: 1, startNumber: "201"), team(id: 2, startNumber: "305")]
        #expect(filterTeams(teams, query: "305").map { $0.id } == [2])
    }

    @Test func filterIsCaseInsensitive() {
        let teams = [team(id: 1, teamname: "Лоси")]
        #expect(filterTeams(teams, query: "ЛОСИ").map { $0.id } == [1])
    }

    @Test func filterEmptyQueryReturnsAll() {
        let teams = [team(id: 1), team(id: 2)]
        #expect(filterTeams(teams, query: "   ").map { $0.id } == [1, 2])
    }

    @Test func filterNoMatch() {
        let teams = [team(id: 1, teamname: "Лоси", startNumber: "201")]
        #expect(filterTeams(teams, query: "zzz").isEmpty)
    }

    @Test func filterNullStartNumberDoesNotCrash() {
        let teams = [team(id: 1, teamname: "Лоси", startNumber: nil)]
        #expect(filterTeams(teams, query: "201").isEmpty)
        #expect(filterTeams(teams, query: "лос").map { $0.id } == [1])
    }

    // --- teamToken ---

    @Test func tokenUsesStartNumber() {
        #expect(teamToken(team(startNumber: "201")) == "201")
    }

    @Test func tokenFallsBackToInitialsWhenNull() {
        #expect(teamToken(team(teamname: "Лесные тропы", startNumber: nil)) == "ЛТ")
    }

    @Test func tokenFallsBackToInitialsWhenEmpty() {
        #expect(teamToken(team(teamname: "Лесные тропы", startNumber: "")) == "ЛТ")
    }

    @Test func tokenFallsBackToIdWhenBothBlank() {
        #expect(teamToken(team(id: 42, teamname: "", startNumber: nil)) == "#42")
    }

    // --- displayTeamName ---

    @Test func displayNameUsesTeamname() {
        #expect(displayTeamName(team(teamname: "Лоси")) == "Лоси")
    }

    @Test func displayNameFallsBackToNumberWhenBlank() {
        #expect(displayTeamName(team(teamname: "", startNumber: "201")) == "Команда 201")
    }

    @Test func displayNameFallsBackToIdWhenBlankAndNoNumber() {
        #expect(displayTeamName(team(id: 7, teamname: "", startNumber: nil)) == "Команда #7")
    }

    // --- initials ---

    @Test func initialsOneWord() {
        #expect(initials("Лоси") == "Л")
    }

    @Test func initialsTwoWords() {
        #expect(initials("лесные тропы") == "ЛТ")
    }

    @Test func initialsRespectsMax() {
        #expect(initials("Альфа Браво Чарли", max: 2) == "АБ")
        #expect(initials("Альфа Браво Чарли", max: 3) == "АБЧ")
    }

    @Test func initialsEmptyString() {
        #expect(initials("") == "")
        #expect(initials("   ") == "")
    }

    // --- peopleWord ---

    @Test func peopleWordSingular() {
        #expect(peopleWord(1) == "человек")
        #expect(peopleWord(21) == "человек")
    }

    @Test func peopleWordFewForm() {
        #expect(peopleWord(2) == "человека")
        #expect(peopleWord(3) == "человека")
        #expect(peopleWord(4) == "человека")
        #expect(peopleWord(22) == "человека")
        #expect(peopleWord(24) == "человека")
    }

    @Test func peopleWordManyForm() {
        #expect(peopleWord(5) == "человек")
        #expect(peopleWord(11) == "человек")
        #expect(peopleWord(12) == "человек")
        #expect(peopleWord(14) == "человек")
        #expect(peopleWord(20) == "человек")
        #expect(peopleWord(100) == "человек")
    }

    // --- peopleLine ---

    @Test func peopleLineWithoutCategory() {
        #expect(peopleLine(category: nil, ucount: 2) == "2 человека")
        #expect(peopleLine(category: nil, ucount: 5) == "5 человек")
    }

    @Test func peopleLineWithCategory() {
        #expect(peopleLine(category: category(), ucount: 3) == "Категория Муж · 3 человека")
        #expect(peopleLine(category: category(), ucount: 1) == "Категория Муж · 1 человек")
    }

    @Test func peopleLineUsesNameWhenShortNameBlank() {
        #expect(peopleLine(category: category(shortName: ""), ucount: 2) == "Категория Мужская · 2 человека")
    }
}
