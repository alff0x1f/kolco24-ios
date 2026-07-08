//
//  TrustedClock.swift
//  kolco24
//
//  Доверенное время: серверный якорь, привязанный к чтению **монотонных** часов
//  (`elapsedRealtime()`-аналог) + идентичность boot-сессии. Порт поведения
//  `data/time/TrustedClock.kt` 1:1 (якорь, регрессия монотонных часов, скью).
//
//  Отличие от Kotlin — идиома конкурентности: вместо `AtomicReference`+`synchronized(lock)`
//  используется `actor` (все чтения/записи сериализованы изоляцией актора, снаружи — через
//  `await`). Вместо `StateFlow` — изолированное свойство `status` + `statusUpdates`
//  (`AsyncStream`, потребитель — UI-баннер этапа 11; значения дедупятся по равенству, как
//  `MutableStateFlow`). Зависимости (провайдеры времени, персистенция якоря) инъектируются,
//  так что ядро Android-/UI-free и async-unit-тестируемо.
//

import Foundation

/// Скью по модулю выше этого порога (мс) переводит `ClockStatus` из `.ok` в `.skewed`.
let SKEW_THRESHOLD_MS: Int64 = 60_000

/// Якорь доверенного времени: серверная эпоха, привязанная к чтению **монотонного**
/// `elapsedRealtime`-таймера, плюс идентичность boot-сессии, в которой чтение было сделано.
///
/// - `serverEpochMs`: серверное время (epoch мс), распарсенное из сетевого `Date`-заголовка.
/// - `anchorElapsedMs`: чтение монотонного `elapsedRealtime()`, к которому привязано серверное
///   время (RTT-скорректированный midpoint).
/// - `capturedWallMs`: wall-часы устройства в момент захвата (только форензика).
/// - `bootCount`: идентичность boot-сессии на момент захвата; `nil`, если прочитать не удалось
///   (тёплый старт тогда отключён, используется эвристика монотонной регрессии). На iOS всегда
///   `nil` — аналога `Settings.Global.BOOT_COUNT` нет.
struct ClockAnchor: Equatable {
    let serverEpochMs: Int64
    let anchorElapsedMs: Int64
    let capturedWallMs: Int64
    let bootCount: Int?
}

/// Единый согласованный снимок всех источников времени, взятый атомарно `TrustedClock.sample`.
///
/// Инвариант: `elapsedMs` — **сырое** чтение `elapsedRealtime()` (`== elapsedProvider()` на момент
/// снимка). Любая прямая математика окна сканирования взаимозаменяема с `elapsedMs` — один
/// монотонный источник, иначе 20-с кольцо прыгнет.
struct TimeSample: Equatable {
    let wallMs: Int64
    let elapsedMs: Int64
    let trustedMs: Int64?
    let bootCount: Int?
}

/// Результат сравнения wall-часов устройства с доверенным временем.
enum ClockStatus: Equatable {
    /// Ещё нет доверенного якоря (холодный старт до первой синхры или инвалидация ребутом).
    case noSync
    /// Wall-часы согласны с доверенным временем в пределах `SKEW_THRESHOLD_MS`.
    case ok
    /// Wall-часы расходятся с доверенным временем на `skewMs` (`wall − trusted`; знак — направление).
    case skewed(skewMs: Int64)
}

/// Чистое ядро доверенного времени. Держит `ClockAnchor` и выводит доверенное время из
/// монотонного `elapsedRealtime()`-таймера — иммунно к изменениям wall-часов (монотонный таймер
/// нельзя перевести из настроек). Только **ребут** ломает якорь (`elapsedRealtime` сбрасывается в 0).
///
/// `trusted = serverEpochMs + (elapsedNow − anchorElapsedMs)`.
actor TrustedClock {

    /// Единый неизменяемый in-memory снимок состояния часов.
    private struct ClockState: Equatable {
        let anchor: ClockAnchor?
        let verified: Bool
    }

    private let elapsedProvider: () -> Int64
    private let wallProvider: () -> Int64
    private let bootCountProvider: () -> Int?
    private let persist: (ClockAnchor) throws -> Void

    private var state: ClockState

    /// Наблюдаемый статус часов; пересчитывается на синхре и на тике.
    private(set) var status: ClockStatus

    /// Поток обновлений статуса (замена `StateFlow`; значения дедупятся по равенству).
    /// Потребитель — UI-баннер этапа 11.
    nonisolated let statusUpdates: AsyncStream<ClockStatus>
    private let continuation: AsyncStream<ClockStatus>.Continuation

    /// - Parameters:
    ///   - elapsedProvider: **сырое** чтение монотонных часов (аналог `SystemClock.elapsedRealtime()`).
    ///   - wallProvider: `System.currentTimeMillis()`-аналог (`Date().timeIntervalSince1970 * 1000`).
    ///   - bootCountProvider: идентичность boot-сессии; на iOS всегда `nil`.
    ///   - persist: best-effort персистенция якоря для тёплого старта (`ClockAnchorStore::write`
    ///     этапа 2); не должна ронять вызывающий поток (оборачивается в `try?`).
    ///   - persisted: якорь, прочитанный обратно при конструировании (тёплый старт).
    init(
        elapsedProvider: @escaping () -> Int64,
        wallProvider: @escaping () -> Int64,
        bootCountProvider: @escaping () -> Int?,
        persist: @escaping (ClockAnchor) throws -> Void = { _ in },
        persisted: ClockAnchor? = nil
    ) {
        self.elapsedProvider = elapsedProvider
        self.wallProvider = wallProvider
        self.bootCountProvider = bootCountProvider
        self.persist = persist

        // Тёплый старт через boot-идентичность (P0, null-safe): оба bootCount должны быть non-nil И
        // равны. `nil == nil` НЕ даёт тёплого старта (это ложно верифицировало бы ребут).
        let currentBoot = bootCountProvider()
        let verified = persisted != nil && currentBoot != nil && persisted!.bootCount == currentBoot
        let initialState = ClockState(anchor: persisted, verified: verified)
        self.state = initialState
        // Засеять статус из тёплого состояния, чтобы у UI на первом кадре был корректный статус
        // (verified → ok/skewed, иначе noSync), а не noSync-до-первого-тика.
        let initialStatus = TrustedClock.computeStatus(
            initialState, elapsedProvider(), wallProvider(), currentBoot
        )
        self.status = initialStatus

        var cont: AsyncStream<ClockStatus>.Continuation!
        self.statusUpdates = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        self.continuation = cont
        cont.yield(initialStatus)
    }

    /// Чисто: доверенная epoch мс из уже захваченного снимка `state` + чтений, или `nil`, когда нет
    /// верифицированного якоря или якорь инвалидирован ребутом. Без сайд-эффектов и вызовов провайдеров.
    ///
    /// Инвалидация ребутом: монотонная регрессия (`anchorElapsedMs > elapsedNow`) **или** оба boot-id
    /// non-nil и различны. Одинокий `nil` boot-id ребута не доказывает (его ловит регрессия).
    private static func computeTrusted(_ state: ClockState, _ elapsedNow: Int64, _ bootNow: Int?) -> Int64? {
        guard state.verified, let anchor = state.anchor else { return nil }
        // Монотонная регрессия = авторитетный детект ребута: якорь не может быть в будущем монотонных
        // часов в той же сессии.
        if anchor.anchorElapsedMs > elapsedNow { return nil }
        if let ab = anchor.bootCount, let bn = bootNow, ab != bn { return nil }
        return anchor.serverEpochMs + (elapsedNow - anchor.anchorElapsedMs)
    }

    /// Чисто: вывести `ClockStatus` из уже захваченного снимка.
    private static func computeStatus(
        _ state: ClockState, _ elapsedNow: Int64, _ wallNow: Int64, _ bootNow: Int?
    ) -> ClockStatus {
        guard let trusted = computeTrusted(state, elapsedNow, bootNow) else { return .noSync }
        let skew = wallNow - trusted
        return abs(skew) > SKEW_THRESHOLD_MS ? .skewed(skewMs: skew) : .ok
    }

    /// Установить и опубликовать статус, дедупя равные значения (как `MutableStateFlow`).
    private func publish(_ newStatus: ClockStatus) {
        guard newStatus != status else { return }
        status = newStatus
        continuation.yield(newStatus)
    }

    /// Доверенная epoch мс, или `nil`, когда не верифицировано / инвалидировано ребутом.
    func trusted() -> Int64? {
        TrustedClock.computeTrusted(state, elapsedProvider(), bootCountProvider())
    }

    /// Доверенная epoch мс для **произвольного** монотонного момента `elapsedAt` (не обязательно
    /// «сейчас»), взятого в boot-сессии `bootAt`; `nil`, когда не верифицировано или момент принадлежит
    /// другой boot-сессии.
    ///
    /// В отличие от `trusted()`/`computeTrusted`, этот путь **не** использует монотонную регрессию как
    /// сигнал ребута: прошлая фиксация законно имеет `elapsedAt < anchorElapsedMs` (точка захвачена
    /// *до* того, как сеть установила якорь сессии), что регрессия ошибочно приняла бы за ребут. Детект
    /// ребута здесь **только** по boot-идентичности. Формула `serverEpochMs + (elapsedAt −
    /// anchorElapsedMs)` корректно экстраполирует в обе стороны (отрицательная Δ для до-якорной точки).
    /// Когда любой boot-id `nil` — свидетельства ребута нет, доверяем и экстраполируем.
    func trustedAt(elapsedAt: Int64, bootAt: Int?) -> Int64? {
        guard state.verified, let anchor = state.anchor else { return nil }
        if let ab = anchor.bootCount, let ba = bootAt, ab != ba { return nil }
        return anchor.serverEpochMs + (elapsedAt - anchor.anchorElapsedMs)
    }

    /// Единый согласованный снимок: одно чтение состояния, один `elapsedProvider`, один
    /// `wallProvider`, один `bootCountProvider`; доверенное время посчитано из тех же захваченных значений.
    func sample() -> TimeSample {
        let elapsedNow = elapsedProvider()
        let wallNow = wallProvider()
        let bootNow = bootCountProvider()
        return TimeSample(
            wallMs: wallNow,
            elapsedMs: elapsedNow,
            trustedMs: TrustedClock.computeTrusted(state, elapsedNow, bootNow),
            bootCount: bootNow
        )
    }

    /// Источник секунд для подписи запросов (`X-App-Ts`): доверенные секунды, когда верифицировано,
    /// иначе честный откат на wall — чтобы подпись пережила скошенные wall-часы, когда якорь установлен.
    func signingSeconds() -> Int64 {
        let s = sample()
        return (s.trustedMs ?? s.wallMs) / 1000
    }

    /// Пере-заякориться из сетевого `Date`-заголовка. `anchorElapsed` — RTT-скорректированный midpoint;
    /// `wallNow`/`bootNow` захвачены вызывающим.
    ///
    /// Правило приёма (P0 + out-of-order + null-safe): принять, если (a) нет текущего якоря; (b)
    /// текущий монотонно невалиден (`anchorElapsedMs > elapsedNow`, ребут) — устаревший отброшен,
    /// входящий принят безусловно; (c) оба boot-id non-nil и различны; или (d) (та же сессия)
    /// `anchorElapsed >= current.anchorElapsedMs` (новее по монотонному времени). Поздний out-of-order
    /// сэмпл с меньшим `anchorElapsed` в той же сессии отвергается (d).
    func onServerTime(serverMs: Int64, anchorElapsed: Int64, wallNow: Int64, bootNow: Int?) {
        let elapsedNow = elapsedProvider()
        let cur = state.anchor
        let accept: Bool
        if let cur {
            if cur.anchorElapsedMs > elapsedNow {
                accept = true // ребут: отбросить устаревший, принять безусловно
            } else if let cb = cur.bootCount, let bn = bootNow, cb != bn {
                accept = true
            } else {
                accept = anchorElapsed >= cur.anchorElapsedMs
            }
        } else {
            accept = true
        }
        if !accept { return }
        let newAnchor = ClockAnchor(
            serverEpochMs: serverMs,
            anchorElapsedMs: anchorElapsed,
            capturedWallMs: wallNow,
            bootCount: bootNow
        )
        let newState = ClockState(anchor: newAnchor, verified: true)
        // Упорядоченный трёх-шаг: state → persist (best-effort) → статус.
        state = newState
        try? persist(newAnchor) // P2: не должно ронять поток вызывающего
        publish(TrustedClock.computeStatus(newState, elapsedNow, wallNow, bootNow))
    }

    /// Пересчитать и опубликовать `status` (драйвится локальным ~5-с тиком). Равные значения дедупятся —
    /// без ложных обновлений.
    func recomputeStatus() {
        publish(TrustedClock.computeStatus(state, elapsedProvider(), wallProvider(), bootCountProvider()))
    }
}
