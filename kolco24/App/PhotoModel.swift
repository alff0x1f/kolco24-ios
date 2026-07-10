//
//  PhotoModel.swift
//  kolco24
//
//  `@Observable @MainActor`-хост-редьюсер фото-отметки. Порт ПОВЕДЕНИЯ (не структуры) трёх мест
//  Android: `onPhotoClick` (`MainActivity.kt` L1050–1073), пикер+коммит (L2062–2139) и
//  `onChangeCheckpoint` (L2089–2094). В Android это размазано по 2220-строчному composable
//  (state-флаги `photoCaptureMarkId`/`showPhotoPicker`/…); на iOS собрано в одну `@Observable`-модель.
//
//  Поток: `start()` — снимок взятий команды → `decidePhotoTarget(marks, now)` → маршрут
//  `.camera(attach: true)` (переиспользуется markId недавнего взятия) или `.picker` (спросить номер
//  КП → свежий UUID → `.camera(attach: false)`). Камера копит кадры; коммит доклеивает (`attachPhotos`)
//  или создаёт standalone фото-марку (`makePhotoMark` + one-shot GPS).
//
//  Дисковые операции — ИНЖЕКТИРОВАННЫЕ замыкания (`writeFrame`/`deleteFrame`), время — `sampleNow`,
//  локация — `CurrentLocationProvider`: модель тестируема без AVFoundation/ImageIO (идиома `TrustedClock`
//  / `ScanModel`). `import SwiftUI`/`GRDB`/`AVFoundation`/`ImageIO` запрещены (grep-инвариант) — хватает
//  `Observation`/`Foundation`; модель зависит только от `Core/`-функций и сторов.
//
//  Записи в БД — в НЕструктурированном `Task`, захватывающем сторы (не `self`): закрытие кавера не
//  обрывает начатый `upsert`/`attachPhotos`/`attachLocation` (§6 этапа 5 — аналог `applicationScope`).
//

import Foundation
import Observation

@MainActor
@Observable
final class PhotoModel: Identifiable {

    /// Стабильный id для `.fullScreenCover(item:)` в `MarksView` (один кавер = одна модель).
    nonisolated let id = UUID()

    /// Куда сейчас смотрит кавер: ещё маршрутизируется (`start()` не завершён), пикер номера КП или
    /// камера (attach — доклейка к существующему взятию).
    enum Route: Equatable {
        case loading
        case picker
        case camera(attach: Bool)
    }

    // MARK: - UI-состояние (observable)

    /// Текущий экран кавера. Стартовое значение — `.loading` (маршрут ещё не решён): вьюха рендерит
    /// НЕинтерактивную заглушку, пока `start()` не выставит `.picker`/`.camera` — зеркалит Android,
    /// решающий attach-vs-picker в `onPhotoClick` ДО композиции оверлея (иначе пользователь мог бы
    /// действовать в пикере до async-резолва, а `start()` затем перезатёр бы маршрут/буфер).
    private(set) var route: Route = .loading
    /// Живой текст числового фильтра пикера (биндится `TextField`). Пустой → вся легенда.
    var query: String = ""
    /// Инлайн-ошибка пикера («КП с таким номером нет в легенде») — сбрасывается на успешном выборе.
    private(set) var pickerError: String?
    /// Наблюдаемая легенда гонки (для фильтра пикера и резолва КП на коммите). Живёт через observation.
    private(set) var legend: [Checkpoint] = []
    /// Относительные пути кадров, снятых В ЭТОЙ сессии (порядок съёмки). Драйвит ленту миниатюр.
    private(set) var frames: [String] = []
    /// Номер КП цели (шапка камеры «КП N»). Ставится на attach-старте и на выборе номера в пикере.
    private(set) var cpNumber: Int = 0
    /// Сигнал закрытия кавера (после коммита). Вьюха его наблюдает.
    private(set) var closeRequested = false

    /// Отфильтрованная легенда пикера (порт `filterCheckpointsByQuery` по `query`).
    var filteredLegend: [Checkpoint] { filterCheckpointsByQuery(legend: legend, query: query) }
    /// Число снятых в этой сессии кадров (для «Готово (N)»).
    var frameCount: Int { frames.count }

    // MARK: - Take-state (не-observable)

    /// Id строки взятия, под которую пишутся кадры (`marks/<markId>/…`). attach — id недавнего взятия;
    /// standalone — свежий UUID, заминченный ДО открытия камеры (кадры пишутся до существования строки).
    @ObservationIgnored private var captureMarkId: String?
    /// Id разрезолвленного КП (для `makePhotoMark` на коммите standalone-ветки).
    @ObservationIgnored private var targetCheckpointId = 0
    /// `TimeSample` первого сохранённого кадра — прокси присутствия (зеркало NFC-тапа); времена марки/attach
    /// берутся отсюда. Ставится ТОЛЬКО на первом кадре, не перештамповывается.
    @ObservationIgnored private var firstSample: TimeSample?

    // MARK: - Зависимости (граф — через AppModel.makePhotoModel)

    /// `nil` допустим (mid-flow дезелект команды): коммит standalone-ветки тогда осиротит кадры (§orphan).
    @ObservationIgnored private let raceId: Int?
    @ObservationIgnored private let teamId: Int?
    @ObservationIgnored private let rosterSize: Int
    @ObservationIgnored private let checkpointStore: CheckpointStore
    @ObservationIgnored private let markStore: MarkStore
    @ObservationIgnored private let locationProvider: any CurrentLocationProvider
    /// Снимок доверенного времени (`trustedClock.sample()` в проде; управляемое время в тестах).
    @ObservationIgnored private let sampleNow: @Sendable () async -> TimeSample
    /// Запись даунскейл-JPEG на диск → относительный путь (`PhotoStorage.writeDownscaledJpeg` в проде).
    /// Блокирующее I/O — вызывается вне main (`Task.detached`). `nil` = битый кадр молча выброшен.
    @ObservationIgnored private let writeFrame: @Sendable (String, Data) -> String?
    /// Удаление кадра+тумбы с диска (`PhotoStorage.deleteFrame` в проде). Вызывается вне main.
    @ObservationIgnored private let deleteFrame: @Sendable (String) -> Void
    /// Генератор id standalone-марки (UUID в проде; детерминированный в тестах).
    @ObservationIgnored private let newMarkId: () -> String

    @ObservationIgnored private var legendTask: Task<Void, Never>?

    init(
        raceId: Int?,
        teamId: Int?,
        rosterSize: Int,
        checkpointStore: CheckpointStore,
        markStore: MarkStore,
        locationProvider: any CurrentLocationProvider,
        sampleNow: @escaping @Sendable () async -> TimeSample,
        writeFrame: @escaping @Sendable (String, Data) -> String?,
        deleteFrame: @escaping @Sendable (String) -> Void,
        newMarkId: @escaping () -> String = { UUID().uuidString }
    ) {
        self.raceId = raceId
        self.teamId = teamId
        self.rosterSize = rosterSize
        self.checkpointStore = checkpointStore
        self.markStore = markStore
        self.locationProvider = locationProvider
        self.sampleNow = sampleNow
        self.writeFrame = writeFrame
        self.deleteFrame = deleteFrame
        self.newMarkId = newMarkId
        startLegendObservation()
    }

    deinit {
        legendTask?.cancel()
    }

    // MARK: - Наблюдение легенды (пикер + резолв на коммите)

    private func startLegendObservation() {
        guard let raceId else { return }
        let observation = checkpointStore.observeCheckpointsForRace(raceId)
        legendTask = Task { [weak self] in
            do {
                for try await checkpoints in observation {
                    guard let self, !Task.isCancelled else { return }
                    self.legend = checkpoints
                }
            } catch {}
        }
    }

    // MARK: - Старт: решение цели (порт onPhotoClick)

    /// Решить точку входа фото-сессии: свежее полное взятие в 3-мин окне → attach-камера (доклейка),
    /// иначе пикер номера КП. «Сейчас» — доверенная эпоха (`trustedMs ?? wallMs`), как `decidePhotoTarget`.
    func start() async {
        guard let teamId else { route = .picker; return }
        let marks = await firstMarks(teamId: teamId)
        let sample = await sampleNow()
        let nowMs = sample.trustedMs ?? sample.wallMs
        switch decidePhotoTarget(marks: marks, nowMs: nowMs) {
        case let .attachTo(markId, cpNumber, checkpointId):
            captureMarkId = markId
            self.cpNumber = cpNumber
            targetCheckpointId = checkpointId
            resetCaptureBuffer()
            route = .camera(attach: true)
        case .askNumber:
            route = .picker
        }
    }

    /// Первое значение observation взятий команды (снимок для `decidePhotoTarget`).
    private func firstMarks(teamId: Int) async -> [Mark] {
        do {
            for try await marks in markStore.observeForTeam(teamId) {
                return marks
            }
        } catch {}
        return []
    }

    // MARK: - Пикер (порт onCheckpointSelected)

    /// Разрешить введённый номер КП против легенды и, при успехе, минтить свежий markId и перейти в
    /// standalone-камеру; номер вне легенды → инлайн-ошибка (без сиротской марки). Залоченные КП
    /// разрешаются намеренно (сценарий «метку сорвали»).
    func submit(number: Int) {
        guard let cp = resolvePhotoCheckpoint(number: number, legend: legend) else {
            pickerError = "КП с таким номером нет в легенде"
            return
        }
        select(cp)
    }

    /// Ввод в поле пикера: фильтр до цифр (поле — номер КП) + сброс устаревшей ошибки (порт `onValueChange`
    /// из `PhotoNumberPicker.kt` — `notFound = false` на каждое изменение), чтобы красная ошибка не висела
    /// до следующего успешного выбора.
    func updateQuery(_ text: String) {
        query = text.filter(\.isNumber)
        pickerError = nil
    }

    /// Тап по строке отфильтрованной легенды — то же, что `submit(number:)` по уже-разрезолвленному КП.
    func select(_ cp: Checkpoint) {
        pickerError = nil
        cpNumber = cp.number
        targetCheckpointId = cp.id
        captureMarkId = newMarkId()
        resetCaptureBuffer()
        route = .camera(attach: false)
    }

    /// Из attach-камеры вернуться в пикер (кнопка «изменить»). Сбрасывает markId цели — станет standalone.
    /// Кадры, снятые В ЭТОЙ сессии, УДАЛЯЮТСЯ с диска перед переходом (1:1 с Android — кнопка «изменить»
    /// в `PhotoCaptureScreen` зовёт `PhotoStorage.deletePhoto` на каждый кадр сессии, затем `frames.clear()`).
    /// Удаляется ТОЛЬКО снятое сейчас: у attach-цели могут быть старые кадры прежнего NFC-взятия — их не
    /// трогаем (они не в `frames`). Логика зеркалит `discard()`.
    func changeCheckpoint() {
        let paths = frames
        captureMarkId = nil
        targetCheckpointId = 0
        resetCaptureBuffer()
        pickerError = nil
        route = .picker
        guard !paths.isEmpty else { return }
        let del = deleteFrame
        Task.detached { for p in paths { del(p) } }
    }

    // MARK: - Буфер кадров

    /// Сохранить снятый JPEG: на первом кадре снимает `firstSample` (прокси присутствия), пишет кадр
    /// вне main через инжектированный `writeFrame`, добавляет относительный путь в ленту. Битый кадр
    /// (`writeFrame == nil`) молча выбрасывается — вьюха никогда не показывает `nil`.
    func addFrame(jpegData: Data) async {
        guard let markId = captureMarkId else { return }
        if firstSample == nil {
            firstSample = await sampleNow()
        }
        let write = writeFrame
        let path = await Task.detached { write(markId, jpegData) }.value
        guard let path else { return }
        frames.append(path)
    }

    /// Удалить один кадр из ленты (тап по «×» на миниатюре) — путь и его тумба сносятся с диска вне main.
    func removeFrame(at index: Int) {
        guard frames.indices.contains(index) else { return }
        let path = frames.remove(at: index)
        let del = deleteFrame
        Task.detached { del(path) }
    }

    /// Выброс всех кадров ЭТОЙ сессии (выход из камеры с кадрами → «Удалить снимки?»). Удаляет ТОЛЬКО
    /// снятое сейчас (у attach-цели могут быть старые кадры — их не трогаем).
    func discard() {
        let paths = frames
        resetCaptureBuffer()
        guard !paths.isEmpty else { return }
        let del = deleteFrame
        Task.detached { for p in paths { del(p) } }
    }

    // MARK: - Коммит (порт onCommit)

    /// Завершить фото-сессию: attach → доклеить пути к существующей строке; standalone → создать
    /// гибрид-марку `method="photo"` + one-shot анти-фрод GPS. Всё в НЕструктурированном `Task`,
    /// захватившем сторы (переживает закрытие кавера, §6). Orphan-ветки (nil race/team или КП
    /// не разрезолвился после mid-flow рефреша легенды) — марки нет, кадры осиротают (sweep подберёт).
    func commit() {
        guard case let .camera(attach) = route else { return }
        let markId = captureMarkId
        let paths = frames
        let sample = firstSample
        let wall = firstSample?.wallMs ?? 0
        let raceId = self.raceId
        let teamId = self.teamId
        let rosterSize = self.rosterSize
        let checkpointId = targetCheckpointId
        let legend = self.legend
        let store = markStore
        let provider = locationProvider

        Task {
            if attach {
                // attach нужен только markId — работаем даже при nil race/team.
                guard let markId else { return }
                try? await store.attachPhotos(id: markId, newPaths: paths, now: wall)
                return
            }
            // Standalone: race/team/markId/sample обязаны быть — иначе кадры осиротают.
            guard let raceIdValue = raceId, let teamIdValue = teamId,
                  let markId, let sample else {
                return
            }
            // КП мог исчезнуть между выбором в пикере и коммитом (рефреш легенды) — тогда сирота.
            guard let cp = legend.first(where: { $0.id == checkpointId }) else { return }
            let mark = makePhotoMark(
                markId: markId, cp: cp, raceId: raceIdValue, teamId: teamIdValue,
                paths: paths, expectedCount: rosterSize, sample: sample
            )
            try? await store.upsert(mark)
            // Анти-фрод: один свежий GPS-фикс на новую фото-марку (паттерн ScanModel.attachLocationForNewTake).
            guard let fix = await provider.current() else { return }
            let s = sanitizeFix(fix)
            try? await store.attachLocation(
                id: markId, lat: s.lat, lon: s.lon, accuracy: s.accuracy,
                altitude: s.altitude, verticalAccuracy: s.verticalAccuracyMeters,
                gpsTimeMs: s.gpsTimeMs, elapsedRealtimeAt: s.elapsedRealtimeAt
            )
        }
        closeRequested = true
    }

    // MARK: - Хелперы

    private func resetCaptureBuffer() {
        frames.removeAll()
        firstSample = nil
    }
}
