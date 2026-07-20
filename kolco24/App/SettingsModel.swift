//
//  SettingsModel.swift
//  kolco24
//
//  `@Observable @MainActor`-модель экрана «Настройки» (этап 9). Порт ПОВЕДЕНИЯ (не структуры)
//  `ui/settings/SettingsScreen.kt` + host-обвязки `MainActivity`: derived-тумблер LAN-режима от
//  lease-стрима, прокси темы/busy к `AppModel`, счётчик точек трека + очистка с guard'ом «не во время
//  записи», отладочные действия (сброс команды, очистка БД), лейбл версии.
//
//  Минтится `AppModel.makeSettingsModel()` для ТЕКУЩЕГО скоупа выбора (`raceId`/`teamId`) — шит
//  открывается для выбранной команды. Держит обратную ссылку на `AppModel` (тема/busy/тосты/сброс
//  команды проксируются туда — app-scoped состояние переживает закрытие шита) и `env` (стор трека +
//  wipe БД). `import SwiftUI`/`GRDB` запрещены (grep-инвариант) — хватает `Observation`;
//  `AsyncStream` lease и `AsyncValueObservation` счётчика трека потребляются без явного упоминания типов.
//

import Foundation
import Observation

@MainActor
@Observable
final class SettingsModel {

    // MARK: - Тема (прокси AppModel)

    /// Текущий режим темы — читается/пишется прямо в `AppModel` (app-scoped, персистит через
    /// `ThemePreference`). `@Observable` трекает доступ к `appModel.themeMode` → перекраска мгновенна.
    var themeMode: ThemeMode {
        get { appModel.themeMode }
        set { appModel.themeMode = newValue }
    }

    // MARK: - LAN-режим (derived от lease)

    /// Последний известный lease (обновляется стримом `LeaseHolder`). Стор для derived-тумблера/сабтайтла.
    private(set) var currentLease: RaceLease?

    /// Тумблер «Локальный сервер» — derived: гонка скоупа запинена к LAN и lease жив. Wall-clock `nowMs`
    /// (deviation плана — `isPinned` нужен синхронно, `TrustedClock` — actor-async).
    var localModeOn: Bool {
        guard let raceId else { return false }
        return isPinned(currentLease, raceId: raceId, nowMs: nowMs())
    }

    /// Сабтайтл ряда LAN-режима: пин → «Локальный режим до HH:mm» (локальная таймзона), иначе
    /// «Обновление из интернета». Спиннер/«Обновление…» при `localModeBusy` рисует вьюха.
    var localModeSubtitle: String {
        guard let raceId, let lease = currentLease, isPinned(lease, raceId: raceId, nowMs: nowMs()) else {
            return "Обновление из интернета"
        }
        return localModeUntilLabel(expiresAtMs: lease.expiresAtMs)
    }

    /// Идёт ли вход/выход LAN-режима — прокси app-scoped `AppModel.localModeBusy` (спиннер тумблера,
    /// переживает закрытие шита; гард от двойного входа живёт в `AppModel.toggleLocalMode`).
    var localModeBusy: Bool { appModel.localModeBusy }

    /// Тумблер LAN-режима: делегирует `AppModel.toggleLocalMode` (fire-and-forget оркестрация +
    /// busy-цикл + тост-исход). Модель не ждёт — тумблер сам пересчитается от lease-стрима.
    func toggleLocalMode(_ on: Bool) {
        appModel.toggleLocalMode(on)
    }

    // MARK: - Трек

    /// Живой счётчик точек трека выбранной команды (сырой, без фильтра точности — сабтайтл «N точек»).
    private(set) var trackPointCount: Int = 0

    /// Можно ли очистить трек: есть точки И рекордер не пишет ЭТУ команду (иначе очистка гонялась бы с
    /// живой вставкой). Порт `trackClearEnabled`.
    var clearTrackEnabled: Bool {
        guard trackPointCount > 0 else { return false }
        if case let .recording(recTeamId) = appModel.trackRecorder.state, recTeamId == teamId {
            return false
        }
        return true
    }

    /// Очистить трек команды: перепроверка `state == .idle` на подтверждении диалога (deviation плана —
    /// без андроидного guard'а под upload-мьютексом: гонка «drain дошлёт удалённую точку» безвредна,
    /// `markUploaded*` по несуществующим id — no-op). Дренаж в unstructured `Task` с захватом СТОРА
    /// (не `self`): закрытие шита не абортит удаление (§6-идиома этапа 5).
    ///
    /// Guard здесь СТРОЖЕ, чем `clearTrackEnabled` (тот блокирует только запись ИМЕННО этой команды):
    /// `state == .idle` отказывает при ЛЮБОЙ активной записи — намеренная защита деструктивного
    /// действия. Расхождение недостижимо в UI (шит скоуп-локальный к выбранной команде, чужая запись
    /// не идёт), но оставлено строгим, чтобы кнопка+действие не могли разойтись при будущих правках.
    func clearTrack() {
        guard appModel.trackRecorder.state == .idle, let teamId, let raceId else { return }
        let store = env.trackStore
        Task { try? await store.deleteForTeam(teamId: teamId, raceId: raceId) }
    }

    // MARK: - Карта гонки

    /// Размер скачанной оффлайн-карты гонки для сабтайтла ряда «Удалить карту гонки» (напр. «12 МБ»);
    /// `nil`, когда файла нет (ряд тогда disabled). Синхронный снимок из инжектированного `mapFileSize`
    /// на момент создания модели (файл-как-флаг не наблюдаем) — обновляется вручную после удаления.
    private(set) var mapFileSizeLabel: String?

    /// Удалить оффлайн-карту гонки: дёргает замыкание графа в unstructured `Task` (захват ЗАМЫКАНИЯ, не
    /// `self` — §6-идиома этапа 5), затем гасит лейбл (ряд становится disabled). Вкладка «Карта»
    /// подхватит удаление в `refreshAvailability` при следующем появлении (файл-как-флаг не наблюдаем).
    func deleteRaceMap() {
        guard let raceId else { return }
        let delete = env.deleteMapFile
        Task { @MainActor [weak self] in
            delete(raceId)
            self?.mapFileSizeLabel = nil
        }
    }

    // MARK: - Отладка

    /// «Сбросить команду» — делегирует `AppModel.clearTeam()` (подписка сама переведёт в empty-состояние).
    func resetTeam() {
        Task { [appModel] in await appModel.clearTeam() }
    }

    /// «Очистить базу данных» — `AppDatabase.wipeAllTables()` (fire-and-forget, захват СТОРА БД, не `self`),
    /// затем снятие LAN-пина (`leaseHolder.set(nil)` — write-through чистит и держатель, и стор) и тост
    /// «База очищена» через `AppModel`. Порт `AppContainer.clearDatabase()` (Kotlin чистит `raceLease`
    /// вместе с таблицами: тумблер LAN-режима не должен указывать на только что стёртую гонку). Схема
    /// остаётся жить — следующий refresh перезальёт данные.
    func wipeDatabase() {
        let database = env.database
        let leaseHolder = env.leaseHolder
        Task { @MainActor [weak self] in
            try? await database.wipeAllTables()
            leaseHolder.set(nil)
            self?.appModel.toastMessage = "База очищена"
        }
    }

    // MARK: - Администратор (этап 10)

    /// Сабтайтл ряда «Администратор»: email при активной сессии, иначе «Войти». Сессия читается
    /// синхронно из держателя на момент создания модели — шит настроек и `fullScreenCover` админа
    /// взаимоисключающи (сессия не меняется, пока ряд «Администратор» на экране), поэтому подписка
    /// на мультиконсумерный `updates` держателя тут не нужна. Свежая модель на каждое открытие
    /// читает актуальное значение.
    let adminSubtitle: String

    // MARK: - Версия

    /// Лейбл «версия (билд)» — из инжектированных значений (тестируемость; прод берёт из `Bundle.main`).
    let versionLabel: String

    // MARK: - Хранимое

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private let appModel: AppModel
    @ObservationIgnored private let raceId: Int?
    @ObservationIgnored private let teamId: Int?
    @ObservationIgnored private let nowMs: () -> Int64
    @ObservationIgnored private var leaseTask: Task<Void, Never>?
    @ObservationIgnored private var trackTask: Task<Void, Never>?

    /// - Parameters:
    ///   - raceId/teamId: скоуп выбранной команды (счётчик трека, пин-чек гонки).
    ///   - versionName/versionCode: `CFBundleShortVersionString`/`CFBundleVersion` — инжектятся для тестов,
    ///     прод-фабрика (`AppModel.makeSettingsModel`) читает `Bundle.main`.
    init(
        env: AppEnvironment,
        appModel: AppModel,
        raceId: Int?,
        teamId: Int?,
        nowMs: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        versionName: String = "",
        versionCode: String = ""
    ) {
        self.env = env
        self.appModel = appModel
        self.raceId = raceId
        self.teamId = teamId
        self.nowMs = nowMs
        self.versionLabel = "\(versionName) (\(versionCode))"
        // Сабтайтл ряда «Администратор»: email активной сессии, иначе «Войти» (синхронный снимок).
        if case let .loggedIn(email, _, _) = appModel.currentAdminSession {
            self.adminSubtitle = email
        } else {
            self.adminSubtitle = "Войти"
        }
        // Синхронный снимок размера скачанной карты гонки (файл-как-флаг не наблюдаем — читаем на открытии).
        if let raceId, let bytes = env.mapFileSize(raceId) {
            self.mapFileSizeLabel = formatBytesRu(bytes)
        } else {
            self.mapFileSizeLabel = nil
        }
        // Сид тумблера синхронно из держателя (стрим догонит асинхронно — без вспышки «выкл» на открытии).
        self.currentLease = env.leaseHolder.value

        // Живой тумблер: подписка на lease-стрим (уже засеян текущим значением в `LeaseHolder`).
        let updates = env.leaseHolder.updates
        leaseTask = Task { [weak self] in
            for await lease in updates {
                guard let self, !Task.isCancelled else { return }
                self.currentLease = lease
            }
        }

        // Счётчик точек трека выбранной команды (только когда скоуп определён).
        if let teamId, let raceId {
            let observation = env.trackStore.countForTeam(teamId: teamId, raceId: raceId)
            trackTask = Task { [weak self] in
                do {
                    for try await count in observation {
                        guard let self, !Task.isCancelled else { return }
                        self.trackPointCount = count
                    }
                } catch {}
            }
        }
    }

    deinit {
        leaseTask?.cancel()
        trackTask?.cancel()
    }
}

/// Человекочитаемый размер файла на русском (Б/КБ/МБ/ГБ, 1024-based). Локаленезависимо и детерминированно
/// (в отличие от `ByteCountFormatter`) — сабтайтл «Удалить карту гонки» и тест читают один и тот же вывод.
/// Целое для Б/точных значений, одна дробь для нецелых КБ+ (12582912 → «12 МБ», 1536 → «1,5 КБ»).
private func formatBytesRu(_ bytes: Int64) -> String {
    let units = ["Б", "КБ", "МБ", "ГБ"]
    var value = Double(max(bytes, 0))
    var idx = 0
    while value >= 1024, idx < units.count - 1 {
        value /= 1024
        idx += 1
    }
    if idx == 0 {
        return "\(Int(value)) \(units[idx])"
    }
    let rounded = (value * 10).rounded() / 10
    if rounded == rounded.rounded() {
        return "\(Int(rounded)) \(units[idx])"
    }
    // Русская запятичная дробь.
    return String(format: "%.1f %@", rounded, units[idx]).replacingOccurrences(of: ".", with: ",")
}
