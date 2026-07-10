//
//  LeaseHolder.swift
//  kolco24
//
//  Единый держатель текущего `RaceLease` (LAN-пин). По-swiftски воспроизводит андроидный
//  `MutableStateFlow<RaceLease?>` с write-through в стор (`AppContainer.kt`): координатор пишет
//  через `set(_:)`, пин-гарды репозиториев читают `value` **синхронно** (`isRacePinned`), UI
//  подписывается на `updates` для живого тумблера. Свежий тип — прямого Kotlin-зеркала нет.
//
//  Потокобезопасность — `NSLock` вокруг значения (аналог `MarkUploadRepository`-actor не подходит:
//  `isRacePinned` обязан быть синхронным, без actor-hop). Поток `updates` следует идиоме
//  `TrustedClock.statusUpdates`: `AsyncStream` с `.bufferingNewest(1)` и ручным дедупом равных
//  значений. Сидится из стора при создании (первое значение сразу в буфере стрима).
//

import Foundation

final class LeaseHolder: @unchecked Sendable {

    private let lock = NSLock()
    private var _value: RaceLease?

    /// Write-through в персистентный стор (`RaceLeaseStore.write`/`clear`), best-effort.
    private let persist: @Sendable (RaceLease?) -> Void

    /// Поток обновлений lease (замена `StateFlow`; равные значения дедупятся).
    /// Потребители — `SettingsModel`-тумблер и любые живые подписчики.
    nonisolated let updates: AsyncStream<RaceLease?>
    private let continuation: AsyncStream<RaceLease?>.Continuation

    /// - Parameters:
    ///   - initial: засеянное значение (обычно `RaceLeaseStore.read()`); сразу кладётся в буфер стрима.
    ///   - persist: write-through-замыкание, вызывается при **изменении** значения.
    init(initial: RaceLease?, persist: @escaping @Sendable (RaceLease?) -> Void) {
        self._value = initial
        self.persist = persist

        var cont: AsyncStream<RaceLease?>.Continuation!
        self.updates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        self.continuation = cont
        cont.yield(initial)
    }

    /// Текущий lease (синхронное чтение под замком — для `isRacePinned`).
    var value: RaceLease? {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    /// Устанавливает lease: дедуп равных (полный no-op — ни persist, ни публикации), иначе
    /// write-through в стор и публикация в стрим.
    func set(_ lease: RaceLease?) {
        lock.lock()
        guard lease != _value else {
            lock.unlock()
            return
        }
        _value = lease
        lock.unlock()

        persist(lease)
        continuation.yield(lease)
    }
}
