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
//  `isRacePinned` обязан быть синхронным, без actor-hop). Поток `updates` — мульти-консумер реестр
//  континуэйшнов, как в `AdminSessionHolder`: `.bufferingNewest(1)`, ручной дедуп равных, каждая
//  подписка — свежий стрим, засеянный текущим значением. Одиночный `let`-стрим умирал навсегда, когда
//  отменялась задача первого подписчика (`deinit` `SettingsModel` при закрытии шита), и повторно
//  открытые «Настройки» переставали видеть смену lease.
//

import Foundation

final class LeaseHolder: @unchecked Sendable {

    private let lock = NSLock()
    private var _value: RaceLease?

    /// Write-through в персистентный стор (`RaceLeaseStore.write`/`clear`), best-effort.
    private let persist: @Sendable (RaceLease?) -> Void

    private var continuations: [Int: AsyncStream<RaceLease?>.Continuation] = [:]
    private var nextContinuationId = 0

    /// - Parameters:
    ///   - initial: засеянное значение (обычно `RaceLeaseStore.read()`).
    ///   - persist: write-through-замыкание, вызывается при **изменении** значения.
    init(initial: RaceLease?, persist: @escaping @Sendable (RaceLease?) -> Void) {
        self._value = initial
        self.persist = persist
    }

    /// Поток обновлений lease (замена `StateFlow`; равные значения дедупятся). **Вычисляемое**:
    /// каждое обращение чеканит свежий стрим, засеянный текущим значением. Потребитель —
    /// `SettingsModel`-тумблер.
    nonisolated var updates: AsyncStream<RaceLease?> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont in
            lock.lock()
            let id = nextContinuationId
            nextContinuationId += 1
            continuations[id] = cont
            // Сид под замком — конкурентный `set(_:)` не доставит более новое значение раньше сида.
            cont.yield(_value)
            lock.unlock()

            cont.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
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
        let targets = Array(continuations.values)
        lock.unlock()

        persist(lease)
        for cont in targets {
            cont.yield(lease)
        }
    }
}
