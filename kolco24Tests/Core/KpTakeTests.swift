//
//  KpTakeTests.swift
//  kolco24Tests
//
//  Зеркало startKpTake-части `data/MarkRepositoryTest.kt` — но над чистой
//  `makeKpTakeMark` (конструирование строки), без БД. DAO-часть (`addMember`,
//  upload-флаги, `attachLocation`) уже зеркалирована `MarkStore`-тестами этапа 2.
//  Кейсы: метаданные+cp-лог, все времена из семпла, null trusted/boot, дедуп
//  двойного слота (не флипает complete раньше времени), пустой буфер, complete при
//  полном буфере, снапшот с null uid — verbatim.
//

import Testing
@testable import kolco24

struct KpTakeTests {

    private func sample(
        wall: Int64 = 1_000,
        elapsed: Int64 = 5_000,
        trusted: Int64? = 2_000,
        boot: Int? = 42
    ) -> TimeSample {
        TimeSample(wallMs: wall, elapsedMs: elapsed, trustedMs: trusted, bootCount: boot)
    }

    private func mem(
        _ n: Int,
        uid: String? = nil,
        number: Int = 0,
        code: String? = nil
    ) -> MarkMemberSnapshot {
        MarkMemberSnapshot(numberInTeam: n, nfcUid: uid, number: number, code: code)
    }

    private func make(
        point: Int = 10,
        cost: Int = 5,
        expectedCount: Int = 3,
        buffered: [MarkMemberSnapshot] = [],
        sample: TimeSample? = nil
    ) -> Mark {
        makeKpTakeMark(
            id: "id-\(point)",
            raceId: 1,
            teamId: 7,
            checkpointId: point,
            number: point,
            cost: cost,
            cpUid: "CPUID\(point)",
            cpCode: "CODE\(point)",
            buffered: buffered,
            expectedCount: expectedCount,
            sample: sample ?? self.sample()
        )
    }

    @Test
    func startKpTake_generatesUniqueIds() {
        // id — параметр (чистота): вызывающий даёт разные UUID разным взятиям.
        let a = makeKpTakeMark(
            id: "A", raceId: 1, teamId: 7, checkpointId: 10, number: 10, cost: 5,
            cpUid: "U", cpCode: "C", buffered: [], expectedCount: 3, sample: sample()
        )
        let b = makeKpTakeMark(
            id: "B", raceId: 1, teamId: 7, checkpointId: 11, number: 11, cost: 5,
            cpUid: "U", cpCode: "C", buffered: [], expectedCount: 3, sample: sample()
        )
        #expect(a.id != b.id)
    }

    @Test
    func startKpTake_storesSnapshotAndCpLog() {
        let mark = make(point: 10, cost: 5, buffered: [mem(1)])
        #expect(mark.checkpointId == 10)
        #expect(mark.checkpointNumber == 10)
        #expect(mark.cost == 5)
        #expect(mark.method == "nfc")
        #expect(mark.cpUid == "CPUID10")
        #expect(mark.cpCode == "CODE10")
        #expect(mark.present == [1])
        #expect(mark.complete == false)
    }

    @Test
    func startKpTake_writesAllTimesFromSample() {
        let mark = make(sample: sample(wall: 1_000, elapsed: 5_000, trusted: 2_000, boot: 42))
        // wall гонит и takenAt, и updatedAt; trusted/elapsed/boot — verbatim.
        #expect(mark.takenAt == 1_000)
        #expect(mark.updatedAt == 1_000)
        #expect(mark.trustedTakenAt == 2_000)
        #expect(mark.elapsedRealtimeAt == 5_000)
        #expect(mark.bootCount == 42)
    }

    @Test
    func startKpTake_nullTrustedAndBoot_persistAsNull() {
        // NoSync (нет якоря часов): trustedMs/bootCount = nil, колонки остаются nil.
        let mark = make(sample: sample(wall: 1_000, elapsed: 5_000, trusted: nil, boot: nil))
        #expect(mark.takenAt == 1_000)
        #expect(mark.trustedTakenAt == nil)
        #expect(mark.elapsedRealtimeAt == 5_000)
        #expect(mark.bootCount == nil)
    }

    @Test
    func startKpTake_completeWhenBufferCoversRoster_scores() {
        let mark = make(expectedCount: 2, buffered: [mem(1), mem(2)])
        #expect(mark.complete == true)
        #expect(takenPoints([mark]) == Set([10]))
    }

    @Test
    func startKpTake_emptyBuffer_notComplete() {
        let mark = make(expectedCount: 3, buffered: [])
        #expect(mark.present.isEmpty)
        #expect(mark.presentDetails == [])
        #expect(mark.complete == false)
    }

    @Test
    func startKpTake_writesPresentDetailsFromBuffer_dedupedByNumberInTeam() {
        let mark = make(
            expectedCount: 3,
            buffered: [
                mem(1, uid: "AA", number: 101),
                mem(2, uid: "BB", number: 102),
                // Дубль слота 1 (двойной тап): должен схлопнуться, не раздуть present/complete.
                mem(1, uid: "AA", number: 101),
            ]
        )
        #expect(mark.present == [1, 2])
        #expect(mark.presentDetails == [mem(1, uid: "AA", number: 101), mem(2, uid: "BB", number: 102)])
        // distinct схлопнул двойной слот — ростер на 3 ещё не complete.
        #expect(mark.complete == false)
    }

    @Test
    func startKpTake_snapshotWithNullUid_storedVerbatim() {
        let mark = make(expectedCount: 1, buffered: [mem(1, uid: nil, number: 0)])
        #expect(mark.presentDetails == [mem(1, uid: nil, number: 0)])
        #expect(mark.complete == true)
    }
}
