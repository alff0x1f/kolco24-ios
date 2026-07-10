//
//  CoreLocationProvider.swift
//  kolco24
//
//  Прод-реализация шва `CurrentLocationProvider` (Core/Track/CurrentLocation) поверх CoreLocation.
//  Порт ПОВЕДЕНИЯ Android-контракта `FusedCurrentLocationProvider` (`data/track/CurrentLocationProvider.kt`),
//  а не структуры: один свежий фикс на вызов, `nil` при таймауте / отказе / ошибке, НИКОГДА не бросает.
//
//  - `current(timeoutMs:)` запускает `CLLocationManager.requestLocation()` (одноразовый запрос,
//    `kCLLocationAccuracyBest`) и гоняет два `Task` в группе: доставку фикса делегатом против таймаута
//    (по умолчанию 8 с, §GPS). Кто первый — тот и ответ; проигравший `Task` снимается.
//  - Маппинг `CLLocation → RawFix`: невалидная `horizontalAccuracy` (< 0) → `Float.greatestFiniteMagnitude`
//    (чистый `sanitizeFix` схлопнёт её в `nil` уже в `ScanModel`); высота/верт.точность — только при
//    валидной `verticalAccuracy`. Свежесть — обязательна: фикс старше `MAX_FIX_AGE_MS` (10 с) режется
//    чистым `isFixFresh` (для анти-фрода «нет координаты» лучше устаревшей).
//  - `elapsedRealtimeNanos` синтезируется из монотонных `mach_continuous_time()` минус wall-возраст фикса
//    (у iOS `CLLocation` нет монотонной метки как у Android `Location.elapsedRealtimeNanos`) — так и
//    `isFixFresh`, и колонка `elapsedRealtimeAt` (через `sanitizeFix`) получают согласованный момент.
//  - `requestWhenInUseAuthorization()` — хук для запроса разрешения заранее, при первом открытии
//    скан-оверлея (вызывается из `ScanSheet` в задаче 8); отказ ничего не блокирует — `current` вернёт `nil`.
//
//  `import CoreLocation` живёт только под `Location/` (grep-инвариант этапа 5).
//

import CoreLocation
import Foundation

/// One-shot GPS-провайдер анти-фрод-координаты поверх `CLLocationManager`. Держит изменяемое состояние
/// (ожидающий `continuation` делегатного колбэка), поэтому финальный класс; состояние трогается с
/// делегатной очереди CoreLocation и с `Task`-таймаута — защищено `lock`, повторный resume исключён.
final class CoreLocationProvider: NSObject, CurrentLocationProvider {

    private let manager: CLLocationManager
    private let lock = NSLock()
    /// Единственный ожидающий вызов `current` (usage — один скан за раз); при перекрытии старый
    /// континуейшн резолвится `nil`, чтобы не подвиснуть.
    private var continuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        manager = CLLocationManager()
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Запросить разрешение «при использовании» заранее (первое открытие скан-оверлея, как в Android).
    /// Отказ ничего не ломает — `current` просто вернёт `nil`.
    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    // MARK: - CurrentLocationProvider

    /// Один свежий фикс или `nil`. Никогда не бросает: таймаут / отказ в разрешении / ошибка провайдера /
    /// несвежий фикс → `nil`.
    func current(timeoutMs: Int64) async -> RawFix? {
        let location: CLLocation? = await withTaskGroup(of: CLLocation?.self) { group in
            group.addTask { await self.awaitNextFix() }
            group.addTask {
                let ns = UInt64(max(0, timeoutMs)) &* 1_000_000
                try? await Task.sleep(nanoseconds: ns)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let location else { return nil }

        let nowNanos = CLLocationMapping.continuousNanos()
        let fix = CLLocationMapping.makeRawFix(from: location, nowNanos: nowNanos)
        guard isFixFresh(fix, nowElapsedNanos: nowNanos) else { return nil }
        return fix
    }

    // MARK: - Мост делегат → async

    /// Ждёт первый фикс (или ошибку → `nil`) от `requestLocation()`. На отмене `Task` (таймаут выиграл)
    /// континуейшн резолвится `nil` из обработчика отмены, иначе `withTaskGroup` подвиснет, ожидая
    /// завершения дочернего `Task`.
    private func awaitNextFix() async -> CLLocation? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<CLLocation?, Never>) in
                if Task.isCancelled {
                    cont.resume(returning: nil)
                    return
                }
                // Перекрывающий вызов: старый континуейшн резолвим, чтобы не осиротел.
                lock.lock()
                let previous = continuation
                continuation = cont
                lock.unlock()
                previous?.resume(returning: nil)

                // Делегатные колбэки CoreLocation ждут run loop потока-создателя менеджера (main).
                DispatchQueue.main.async { self.manager.requestLocation() }
            }
        } onCancel: {
            resumePending(with: nil)
        }
    }

    /// Резолвит ожидающий континуейшн ровно один раз (гвард двойного resume).
    private func resumePending(with location: CLLocation?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: location)
    }

}

// MARK: - CLLocationManagerDelegate

extension CoreLocationProvider: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        resumePending(with: locations.last)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        resumePending(with: nil)
    }
}
