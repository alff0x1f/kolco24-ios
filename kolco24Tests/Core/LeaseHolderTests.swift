//
//  LeaseHolderTests.swift
//  kolco24Tests
//
//  Свежие тесты `LeaseHolder` (прямого Kotlin-зеркала нет): сид из стора (начальное значение),
//  write-through в persist-замыкание, публикация изменений в стрим и дедуп равных.
//

import Foundation
import Testing
@testable import kolco24

struct LeaseHolderTests {

    /// Потокобезопасный лог вызовов persist (замыкание `@Sendable`).
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [RaceLease?] = []

        func record(_ lease: RaceLease?) {
            lock.lock(); defer { lock.unlock() }
            _calls.append(lease)
        }

        var calls: [RaceLease?] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
    }

    private let leaseA = RaceLease(raceId: 1, expiresAtMs: 1_000)
    private let leaseB = RaceLease(raceId: 2, expiresAtMs: 2_000)

    // MARK: value / seed

    @Test
    func value_seedsFromInitial() {
        let holder = LeaseHolder(initial: leaseA, persist: { _ in })
        #expect(holder.value == leaseA)
    }

    @Test
    func value_seedsNil_whenNoInitial() {
        let holder = LeaseHolder(initial: nil, persist: { _ in })
        #expect(holder.value == nil)
    }

    // MARK: write-through

    @Test
    func set_updatesValueAndWritesThrough() {
        let rec = Recorder()
        let holder = LeaseHolder(initial: nil, persist: { rec.record($0) })

        holder.set(leaseB)

        #expect(holder.value == leaseB)
        #expect(rec.calls == [leaseB])
    }

    @Test
    func set_nil_writesThroughNil() {
        let rec = Recorder()
        let holder = LeaseHolder(initial: leaseA, persist: { rec.record($0) })

        holder.set(nil)

        #expect(holder.value == nil)
        #expect(rec.calls == [nil])
    }

    @Test
    func set_dedupsEqual_noWriteThrough() {
        let rec = Recorder()
        let holder = LeaseHolder(initial: leaseA, persist: { rec.record($0) })

        holder.set(leaseA)   // равно текущему — полный no-op

        #expect(rec.calls.isEmpty)
        #expect(holder.value == leaseA)
    }

    // MARK: stream

    @Test
    func stream_publishesInitialThenChanges() async {
        let holder = LeaseHolder(initial: leaseA, persist: { _ in })
        var iter = holder.updates.makeAsyncIterator()

        let first = await iter.next()
        #expect((first ?? nil) == leaseA)

        holder.set(leaseB)
        let second = await iter.next()
        #expect((second ?? nil) == leaseB)
    }

    @Test
    func stream_dedupsEqual() async {
        let holder = LeaseHolder(initial: leaseA, persist: { _ in })
        var iter = holder.updates.makeAsyncIterator()

        _ = await iter.next()   // засеянное leaseA

        holder.set(leaseA)      // дедуп — не публикуется
        holder.set(leaseB)      // публикуется

        let next = await iter.next()
        #expect((next ?? nil) == leaseB)   // не повторное leaseA — равный set пропущен
    }
}
