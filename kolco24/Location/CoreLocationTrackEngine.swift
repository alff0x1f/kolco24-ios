//
//  CoreLocationTrackEngine.swift
//  kolco24
//
//  Прод-реализация шва `TrackEngine` (Core/Track/TrackEngine) поверх CoreLocation. Единственный новый
//  `import CoreLocation`-файл этапа 8 (grep-инвариант: CoreLocation живёт только под `Location/`).
//  Device-only — юнитами не кроется (прецедент `NfcChipScanner`/`PhotoCameraController`); поведенческая
//  логика записи кроется `TrackRecorderTests` через seam с `FakeTrackEngine`.
//
//  Фоновая запись — решение брейншторма (адаптация под платформу, не 1в1 из Kotlin):
//  - `CLLocationUpdate.liveUpdates(.fitness)` в `Task` на неизолированном контексте: async-последовательность
//    системных обновлений локации (iOS 17+, таргет 18) — родной аналог андроидного foreground-сервиса;
//  - `CLBackgroundActivitySession` создаётся на старте и инвалидируется на стопе — держит фоновые
//    обновления при уже выданном When-In-Use (этап 5), системный синий индикатор — аналог нотификации;
//  - `update.location == nil` и `update.isStationary` пропускаются (стационарный/пустой апдейт — не фикс);
//  - маппинг `CLLocation → RawFix` теми же правилами, что `CoreLocationProvider` (accuracy < 0 →
//    `Float.greatestFiniteMagnitude`, altitude/верт.точность только при `verticalAccuracy > 0`, монотонный
//    штамп `elapsedRealtimeNanos` из `mach_continuous_time()` минус возраст фикса).
//
//  Force-quit убивает запись — задокументированный факт (аналог `START_NOT_STICKY`: Android при убийстве
//  сервиса тоже не возобновляет).
//

import CoreLocation
import Foundation

/// Прод-движок GPS-трека поверх `CLLocationUpdate.liveUpdates`. Держит изменяемое состояние
/// (`Task`/сессия/континуейшн), поэтому финальный класс; трогается с MainActor (`start`/`stop`) —
/// `@unchecked Sendable`, аффинити держится дисциплиной (одна сессия записи в один момент).
final class CoreLocationTrackEngine: NSObject, TrackEngine, @unchecked Sendable {

    /// Удерживаемый менеджер для чтения `authorizationStatus`/`accuracyAuthorization` (хелперы инжектов
    /// `hasLocationAccess`/`isReducedAccuracy`). Инстанс живёт в адаптере, НЕ одноразовый в замыкании —
    /// одноразовый `CLLocationManager` в замыкании читает статус до инициализации и врёт `.notDetermined`.
    private let manager = CLLocationManager()

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var session: CLBackgroundActivitySession?
    private var continuation: AsyncStream<RawFix>.Continuation?
    /// Поколение активного цикла: инкрементится ТОЛЬКО при старте нового `Task` (не при повторном
    /// `fixes()` на живой сессии). Хвост завершения цикла обнуляет `task`/`continuation` лишь если его
    /// поколение всё ещё текущее — иначе `stop()`/новый `fixes()`, уже подменившие цикл, не пострадают.
    private var generation = 0

    // MARK: - TrackEngine

    /// Открыть фоновую сессию активности и запустить цикл `liveUpdates(.fitness)`. Первый `fixes()`
    /// стартует движок; повторный вызов при живой сессии просто выдаёт новый стрим (запись держит один).
    func fixes() -> AsyncStream<RawFix> {
        AsyncStream { cont in
            lock.lock()
            // Уже запущены — переустанавливаем континуейшн (запись держит один активный стрим).
            continuation?.finish()
            continuation = cont
            if session == nil {
                session = CLBackgroundActivitySession()
            }
            let alreadyRunning = task != nil
            var gen = 0
            if !alreadyRunning {
                generation += 1
                gen = generation
            }
            lock.unlock()

            guard !alreadyRunning else { return }

            let t = Task { [weak self] in
                guard let self else { return }
                do {
                    let updates = CLLocationUpdate.liveUpdates(.fitness)
                    for try await update in updates {
                        if Task.isCancelled { break }
                        // Стационарный или пустой апдейт — не фикс.
                        guard !update.isStationary, let loc = update.location else { continue }
                        let nowNanos = CLLocationMapping.continuousNanos()
                        let fix = CLLocationMapping.makeRawFix(from: loc, nowNanos: nowNanos)
                        self.lock.lock()
                        // Йелдим ТОЛЬКО пока поколение наше: после `stop()`+нового `fixes()` (retained-инстанс)
                        // `self.continuation` — уже НОВЫЙ стрим, а `generation` инкрементнут → читаем `nil` и
                        // не роняем устаревший фикс старой сессии в чужой сегмент. На живой сессии
                        // (повторный `fixes()` переустановил континуейшн) `generation == gen` — йелдим в текущий.
                        let cont = self.generation == gen ? self.continuation : nil
                        self.lock.unlock()
                        cont?.yield(fix)
                    }
                } catch {
                    // Ошибка потока обновлений (нет разрешения / система прервала) → завершаем стрим.
                }
                // Цикл иссяк сам (ошибка/завершение, не `stop()`): обнуляем `task`/`continuation`, но лишь
                // если это всё ещё НАШЕ поколение — иначе `stop()`/новый `fixes()` уже подменили цикл, и
                // трогать их состояние нельзя (иначе прод-инстанс залипает с «живым» дохлым `task`).
                // Инкремент `generation` инвалидирует поколение, чтобы поздний внешний `task = t` (если цикл
                // завершился ДО того, как `fixes()` дошёл до сохранения хендла) не переустановил дохлый `Task`.
                self.lock.lock()
                var cont: AsyncStream<RawFix>.Continuation?
                if self.generation == gen {
                    cont = self.continuation
                    self.continuation = nil
                    self.task = nil
                    self.generation += 1
                }
                self.lock.unlock()
                cont?.finish()
            }

            // Сохраняем хендл лишь если наше поколение ещё активно: быстро завершившийся цикл уже мог
            // пройти хвост (обнулив `task` и инкрементнув `generation`) — тогда `generation != gen` и мы
            // НЕ переустанавливаем дохлый `Task` (иначе `alreadyRunning == true` навсегда → мёртвый стрим).
            lock.lock()
            if generation == gen {
                task = t
            }
            lock.unlock()
        }
    }

    /// Остановить обновления и завершить стрим. Идемпотентен: отменяет `Task`, инвалидирует фоновую
    /// сессию, резолвит континуейшн.
    func stop() {
        lock.lock()
        let t = task
        task = nil
        let s = session
        session = nil
        let cont = continuation
        continuation = nil
        lock.unlock()
        t?.cancel()
        s?.invalidate()
        cont?.finish()
    }

    // MARK: - Хелперы инжектов (читают удерживаемый менеджер)

    /// Запросить разрешение «при использовании» заранее — при тапе «Начать запись» (аналог того, как
    /// `ScanSheet` прогревает разрешение при первом открытии оверлея). Идемпотентно: если статус уже
    /// определён (выдан/отклонён), система ничего не показывает; при `.notDetermined` — системный диалог.
    /// Отказ ничего не ломает — `hasLocationAccess()` останется `false`, старт запишет тост.
    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    /// Есть ли разрешение на геолокацию «при использовании» или «всегда» (TOCTOU-проверка перед стартом
    /// записи). Читает `authorizationStatus` с удерживаемого менеджера.
    func hasLocationAccess() -> Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return true
        default:
            return false
        }
    }

    /// Выдана ли только «примерная» локация (iOS-аналог андроидного «нет GPS-провайдера» → деградация
    /// точности в TrackCard). Читает `accuracyAuthorization` с удерживаемого менеджера.
    func isReducedAccuracy() -> Bool {
        manager.accuracyAuthorization == .reducedAccuracy
    }

}
