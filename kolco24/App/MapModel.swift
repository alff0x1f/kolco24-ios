//
//  MapModel.swift
//  kolco24
//
//  `@Observable @MainActor`-модель вкладки «Карта». Android-зеркала нет (вкладка iOS-only). Держит
//  сырые данные трёх observation'ов (точки GPS-трека выбранной команды, взятия команды, КП гонки) и
//  отдаёт готовые к рендеру производные для `TrackMapView` (задача 6) плюс машину состояний скачивания
//  оффлайн-подложки (`MapAvailability`).
//
//  ТИПЫ КООРДИНАТ: модель оперирует ТОЛЬКО парами `Double` lat/lon — `CLLocationCoordinate2D` появляется
//  исключительно внутри `Map/TrackMapView`. Иначе `App/MapModel` потребовал бы `import CoreLocation`,
//  ломая grep-инвариант (`import` только `Observation`/`Foundation`). Дисковые/сетевые операции —
//  инжектированные замыкания графа (`mapFileExists`/`mapFilePath`/`downloadMapFile`/…), так что модель
//  тестируется без сети/диска/MapKit.
//
//  Точки трека нуждаются в ОБОИХ ключах (`observeForTeam` скоупит по `teamId` + `raceId`), взятия — в
//  `teamId`, КП — в `raceId`, поэтому `rebind(teamId:raceId:)` перезапускает все три наблюдения со
//  stale-guard (конвенция пер-таб моделей этапа 4: до первой эмиссии новой пары массивы чистятся
//  синхронно, чтобы данные прежней команды не участвовали в derived), а заодно пересчитывает
//  доступность подложки для новой гонки (и отменяет активное скачивание при подлинной смене команды).
//
//  `import SwiftUI`/`GRDB`/`MapKit`/`CoreLocation` запрещены (grep-инвариант) — хватает `Observation`;
//  `AsyncValueObservation` сторов потребляется без явного упоминания GRDB-типов.
//

import Foundation
import Observation

/// Один пин взятого КП на карте: координата — GPS-фикс самого взятия (`Mark.locLat`/`locLon`), номер и
/// живая цена — из легенды (фолбэк на снимок взятия), время — доверенное, если есть. Только пары `Double`
/// (никакого `CLLocationCoordinate2D`) — конверсия в MapKit-тип живёт в `TrackMapView`.
struct MapMarkPin: Equatable {
    let lat: Double
    let lon: Double
    /// Номер КП (из легенды по `checkpointId`, фолбэк — снимок `checkpointNumber` взятия).
    let number: Int
    /// Живая цена КП: `checkpointCosts[id] ?? mark.cost` (locked-КП без цены → снимок взятия).
    let cost: Int
    /// Время взятия: `trustedTakenAt ?? takenAt` (epoch-ms).
    let timeMs: Int64
}

/// Машина состояний доступности оффлайн-подложки гонки. `noMapForRace` — у гонки `mapUrl == nil`;
/// `notDownloaded`/`ready` — файл `.mbtiles` есть/нет на диске; `downloading` — активное скачивание с
/// прогрессом `0…1`; `failed` — ошибка скачивания (сопровождается тостом; CTA возвращается в
/// `notDownloaded` при следующем `refreshAvailability`).
enum MapAvailability: Equatable {
    case noMapForRace
    case notDownloaded
    case downloading(progress: Double)
    case ready(path: String)
    case failed(message: String)
}

@MainActor
@Observable
final class MapModel {

    /// Сырые точки GPS-трека выбранной команды (уже отсортированы SQL). Пусто между `rebind` и первой
    /// эмиссией новой команды (stale-guard).
    private(set) var trackPoints: [TrackPoint] = []
    /// Взятия выбранной команды (newest-first, как отдаёт стор) — источник пинов КП (с GPS-фиксом).
    private(set) var marks: [Mark] = []
    /// КП текущей гонки — источник живой цены/номера пина (`checkpointsById`).
    private(set) var checkpoints: [Checkpoint] = []
    /// Доступность оффлайн-подложки (машина состояний скачивания).
    private(set) var availability: MapAvailability = .noMapForRace

    @ObservationIgnored private let env: AppEnvironment
    /// Тост об ошибке скачивания (прод — прокидывает в `AppModel.toastMessage`; тесты — рекордер).
    @ObservationIgnored private let onToast: (String) -> Void
    /// Разрешённый URL подложки текущей гонки (из `Race.mapUrl`) — цель `downloadMap`. `nil`, пока
    /// доступность не пересчитана / у гонки нет карты.
    @ObservationIgnored private var mapUrl: String?

    @ObservationIgnored private var trackTask: Task<Void, Never>?
    @ObservationIgnored private var marksTask: Task<Void, Never>?
    @ObservationIgnored private var checkpointsTask: Task<Void, Never>?
    @ObservationIgnored private var availabilityTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    /// Команда/гонка активных наблюдений — для идемпотентности `rebind` на той же паре.
    @ObservationIgnored private var boundTeamId: Int?
    @ObservationIgnored private var boundRaceId: Int?

    init(env: AppEnvironment, onToast: @escaping (String) -> Void = { _ in }) {
        self.env = env
        self.onToast = onToast
    }

    deinit {
        trackTask?.cancel()
        marksTask?.cancel()
        checkpointsTask?.cancel()
        availabilityTask?.cancel()
        downloadTask?.cancel()
    }

    // MARK: - Жизненный цикл

    /// Перепривязывает наблюдения трека/взятий команды [teamId] и КП гонки [raceId] (или снимает при
    /// `nil`). Идемпотентно для той же пары. Stale-guard: до первой эмиссии новой пары массивы чистятся
    /// синхронно. Подлинная смена команды отменяет активное скачивание (не докачиваем чужую гонку) и
    /// пересчитывает доступность подложки для новой гонки.
    func rebind(teamId: Int?, raceId: Int?) {
        if teamId == boundTeamId, raceId == boundRaceId,
           trackTask != nil || marksTask != nil || checkpointsTask != nil {
            return
        }
        trackTask?.cancel()
        marksTask?.cancel()
        checkpointsTask?.cancel()
        downloadTask?.cancel()
        downloadTask = nil
        trackPoints = []
        marks = []
        checkpoints = []
        availability = .noMapForRace
        mapUrl = nil
        boundTeamId = teamId
        boundRaceId = raceId

        if let teamId, let raceId {
            let observation = env.trackStore.observeForTeam(teamId: teamId, raceId: raceId)
            trackTask = Task { [weak self] in
                do {
                    for try await points in observation {
                        guard let self, !Task.isCancelled else { return }
                        self.trackPoints = points
                    }
                } catch {}
            }
        }

        if let teamId {
            let observation = env.markStore.observeForTeam(teamId)
            marksTask = Task { [weak self] in
                do {
                    for try await rows in observation {
                        guard let self, !Task.isCancelled else { return }
                        self.marks = rows
                    }
                } catch {}
            }
        }

        if let raceId {
            let observation = env.checkpointStore.observeCheckpointsForRace(raceId)
            checkpointsTask = Task { [weak self] in
                do {
                    for try await rows in observation {
                        guard let self, !Task.isCancelled else { return }
                        self.checkpoints = rows
                    }
                } catch {}
            }
        }

        refreshAvailability()
    }

    /// Пересчитывает доступность подложки от файловой системы (и `mapUrl` гонки). Вызывается из
    /// `MapTabView` в `.task`/`onAppear` — вкладки в `TabView` живут постоянно, а удаление карты в
    /// настройках иначе не долетело бы до уже созданной модели (файл-как-флаг не наблюдаем). Не трогает
    /// активное скачивание (`downloading`). `mapUrl == nil` → `noMapForRace`; файл есть → `ready(path)`;
    /// иначе → `notDownloaded`.
    func refreshAvailability() {
        if case .downloading = availability { return }
        guard let raceId = boundRaceId else {
            availability = .noMapForRace
            mapUrl = nil
            return
        }
        availabilityTask?.cancel()
        availabilityTask = Task { [weak self] in
            guard let self else { return }
            let race = (try? await self.env.raceStore.getById(raceId)) ?? nil
            guard !Task.isCancelled, self.boundRaceId == raceId else { return }
            if case .downloading = self.availability { return }
            guard let url = race?.mapUrl, !url.isEmpty else {
                self.availability = .noMapForRace
                self.mapUrl = nil
                return
            }
            self.mapUrl = url
            if self.env.mapFileExists(raceId) {
                self.availability = .ready(path: self.env.mapFilePath(raceId))
            } else {
                self.availability = .notDownloaded
            }
        }
    }

    // MARK: - Действия скачивания

    /// Скачать подложку текущей гонки: прогресс → `downloading(p)`, успех → `ready`, ошибка → `failed`
    /// + тост, отмена → назад в `notDownloaded` молча (сторэдж чистит temp). Guard от повторного входа —
    /// если уже `downloading`. Захватывает замыкание графа (не `self`) для самого скачивания.
    func downloadMap() {
        guard let raceId = boundRaceId, let urlString = mapUrl, let url = URL(string: urlString) else { return }
        if case .downloading = availability { return }
        availability = .downloading(progress: 0)
        let download = env.downloadMapFile
        downloadTask = Task { [weak self] in
            do {
                try await download(url, raceId) { progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.boundRaceId == raceId,
                              case .downloading = self.availability else { return }
                        self.availability = .downloading(progress: progress)
                    }
                }
                guard let self, !Task.isCancelled, self.boundRaceId == raceId else { return }
                // Снимаем `downloading` напрямую (не через `refreshAvailability` — тот
                // короткозамыкается на активном `downloading`): файл на месте → `ready(path)`.
                if self.env.mapFileExists(raceId) {
                    self.availability = .ready(path: self.env.mapFilePath(raceId))
                } else {
                    self.availability = .notDownloaded
                }
            } catch is CancellationError {
                // Отмена (смена команды / `cancelDownload`): сторэдж уже снёс temp, оставляем состояние
                // тому, кто отменил (`cancelDownload` ставит `notDownloaded`, `rebind` — сбрасывает всё).
                return
            } catch {
                guard let self, self.boundRaceId == raceId else { return }
                let message = "Не удалось скачать карту гонки"
                self.availability = .failed(message: message)
                self.onToast(message)
            }
        }
    }

    /// Отмена активного скачивания: снимает `Task` (сторэдж чистит temp) и возвращает состояние в
    /// `notDownloaded`. Идемпотентно (вне `downloading` — no-op по состоянию).
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        if case .downloading = availability {
            availability = .notDownloaded
        }
    }

    // MARK: - Derived (для TrackMapView)

    /// Путь трека для полилинии: отфильтрованные по точности и reboot-safe отсортированные точки как пары
    /// `Double` lat/lon (порт `trackUsable` из `TeamModel`; конверсия в `CLLocationCoordinate2D` — в
    /// `TrackMapView`, иначе модель потребовала бы `import CoreLocation`).
    var trackPath: [(lat: Double, lon: Double)] {
        sortedTrackPoints(filterPoints(trackPoints)).map { (lat: $0.lat, lon: $0.lon) }
    }

    /// КП текущей гонки по id — для номера/живой цены пина.
    private var checkpointsById: [Int: Checkpoint] {
        Dictionary(checkpoints.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Пины взятых КП с GPS-фиксом (`locLat`/`locLon != nil`). Взятия без фикса на карте не
    /// показываются — осознанно (координаты КП с сервера не приходят). Номер/цена — из легенды с
    /// фолбэком на снимок взятия; время — `trustedTakenAt ?? takenAt`.
    var pins: [MapMarkPin] {
        let byId = checkpointsById
        return marks.compactMap { mark in
            guard let lat = mark.locLat, let lon = mark.locLon else { return nil }
            let cp = byId[mark.checkpointId]
            return MapMarkPin(
                lat: lat,
                lon: lon,
                number: cp?.number ?? mark.checkpointNumber,
                cost: cp?.cost ?? mark.cost,
                timeMs: mark.trustedTakenAt ?? mark.takenAt
            )
        }
    }
}
