//
//  TrackMapView.swift
//  kolco24
//
//  `UIViewRepresentable` над `MKMapView` для вкладки «Карта»: живой GPS-трек
//  команды (полилиния) + взятые КП (аннотации) поверх оффлайн-подложки MBTiles
//  (или Apple-подложки, если карта не скачана). Живёт под `Map/` — единственный
//  дом `import MapKit` (grep-инвариант; прецедент `Photo/CameraPreviewView`).
//
//  ТИПЫ КООРДИНАТ: `CLLocationCoordinate2D` появляется ТОЛЬКО здесь — конверсия из
//  пар `Double` lat/lon (`trackLines`/`MapMarkPin`), которые готовит `MapModel`.
//
//  Трек — линии фильтра выбросов: линии из ≥ 2 точек идут одним `MKMultiPolyline` (между линиями
//  ничего не рисуется), одиночные фиксы — точки-аннотации (иначе первый фикс живого хвоста после
//  разрыва не был бы виден до следующего).
//  Раскраска по скорости (`speedRuns != nil`): тёмная подложка под ранами диапазонов (не под `.gap` —
//  иначе пунктир читался бы сплошной линией), поверх — по одному `MKMultiPolyline` на штрих; стоянки —
//  подписи «12 мин», обновляются дифом по `MapStopPin` (иначе каждый фикс закрывал бы выноску).
//  Иначе `App/MapModel` потребовал бы `import CoreLocation`, ломая grep-инвариант.
//  `import SwiftUI` нужен для дизайн-токенов (`UIColor(Color.brandRed/.kolcoOrange)`,
//  адаптивность сохраняется) — под `Map/` это не запрещено.
//
//  Устройство-only, unit-тестов нет (прецедент `NfcChipScanner`/
//  `PhotoCameraController`) — поведенческая логика вынесена в `Core/Map` и `MapModel`.
//

import MapKit
import SwiftUI

/// Дескриптор активной оффлайн-подложки: источник тайлов + метаданные (bbox/зумы).
/// `nil` во входах `TrackMapView` = карта не скачана → штатная Apple-подложка.
struct MapOverlayDescriptor {
    let metadata: MBTilesMetadata?
    let tileData: @Sendable (Int, Int, Int) -> Data?
}

/// Разовый перелёт камеры по кнопке на карте.
enum MapCameraCommand {
    /// Показать скачанную карту гонки по её `bounds`.
    case raceMap
    /// Центр на последнем GPS-фиксе.
    case myLocation
}

/// Запрос перелёта: новый `id` — новое нажатие (та же команда повторяется).
struct MapCameraRequest: Equatable {
    let command: MapCameraCommand
    let id: Int
}

/// Карта команды: трек-полилиния + пины КП поверх MBTiles-подложки или Apple-fallback.
struct TrackMapView: UIViewRepresentable {
    /// Линии трека парами `Double` (уже отфильтрованы/отсортированы в `MapModel`).
    let trackLines: [[(lat: Double, lon: Double)]]
    /// Раны раскраски по скорости; `nil` — одноцветный трек по `trackLines`.
    let speedRuns: [(stroke: SpeedStroke, coords: [(lat: Double, lon: Double)])]?
    /// Стоянки (только в режиме раскраски).
    let stopPins: [MapStopPin]
    /// Пины взятых КП (только с GPS-фиксом).
    let pins: [MapMarkPin]
    /// Оффлайн-подложка (`nil` → Apple-тайлы онлайн).
    let overlay: MapOverlayDescriptor?
    /// Последнее нажатие кнопки камеры; выполняется один раз на `id`.
    let cameraRequest: MapCameraRequest?
    /// «Моё местоположение» без GPS-фикса.
    let onNoLocationFix: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = LayoutAwareMapView()
        let coordinator = context.coordinator
        // Пересоздание вида (`.id` по пути подложки) не должно повторять прошлое нажатие.
        coordinator.lastRequestId = cameraRequest?.id
        let metadata = overlay?.metadata
        mapView.onLayout = { [weak mapView, weak coordinator] in
            guard let mapView, let coordinator, coordinator.pendingRaceMap else { return }
            Self.frameRaceMap(mapView, metadata: metadata, coordinator: coordinator, animated: false)
        }
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.register(
            CheckpointAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: CheckpointAnnotationView.reuseId
        )
        mapView.register(StopAnnotationView.self, forAnnotationViewWithReuseIdentifier: StopAnnotationView.reuseId)

        // Оффлайн-подложка добавляется ОДИН раз (при наличии) — поверх Apple-тайлов.
        if let overlay {
            let tileOverlay = MBTilesOverlay(metadata: overlay.metadata, tileData: overlay.tileData)
            mapView.addOverlay(tileOverlay, level: .aboveLabels)
            // Флаг ставим ТОЛЬКО если камера реально спозиционирована по bounds. Без валидных
            // bounds `frameRaceMap` возвращает false → падаем в `applyData`, где камера
            // подгоняется под трек/пины (иначе карта открылась бы в дефолтном регионе с данными
            // команды за кадром).
            if Self.frameRaceMap(mapView, metadata: overlay.metadata, coordinator: coordinator, animated: false) {
                coordinator.didSetInitialCamera = true
            }
        }

        applyData(mapView, coordinator: context.coordinator)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        applyData(mapView, coordinator: context.coordinator)
        if let cameraRequest, cameraRequest.id != context.coordinator.lastRequestId {
            context.coordinator.lastRequestId = cameraRequest.id
            runCameraCommand(cameraRequest.command, mapView: mapView, coordinator: context.coordinator)
        }
    }

    // MARK: - Рендер данных

    /// Полная замена полилинии и пинов (без инкрементального аппенда). При первой порции данных без
    /// оффлайн-подложки — однократная подгонка камеры под трек/пины.
    private func applyData(_ mapView: MKMapView, coordinator: Coordinator) {
        // Полилинии: снять старые, положить новые.
        mapView.removeOverlays(coordinator.trackOverlays)
        coordinator.trackOverlays = []
        coordinator.strokeStyles = [:]
        let lines = trackLines.map(Self.coordinates)
        if let speedRuns {
            let bandRuns = speedRuns.filter { $0.stroke != .gap }.map { Self.coordinates($0.coords) }
            addTrackOverlay(mapView, coordinator: coordinator, lines: bandRuns, style: .casing)
            let strokes: [SpeedStroke] = [.gap] + SpeedBand.allCases.map { .band($0) }
            for stroke in strokes {
                let runs = speedRuns.filter { $0.stroke == stroke }.map { Self.coordinates($0.coords) }
                addTrackOverlay(mapView, coordinator: coordinator, lines: runs, style: .stroke(stroke))
            }
        } else {
            addTrackOverlay(mapView, coordinator: coordinator, lines: lines, style: .plain)
        }

        if coordinator.stopPins != stopPins {
            updateStopAnnotations(mapView)
            coordinator.stopPins = stopPins
        }

        // Одиночные фиксы — точки.
        mapView.removeAnnotations(mapView.annotations.compactMap { $0 as? TrackDotAnnotation })
        mapView.addAnnotations(lines.compactMap { $0.count == 1 ? TrackDotAnnotation(coordinate: $0[0]) : nil })
        let coords = lines.flatMap { $0 }

        // Пины КП: снять прежние аннотации КП, положить свежие.
        let staleAnnotations = mapView.annotations.compactMap { $0 as? CheckpointAnnotation }
        mapView.removeAnnotations(staleAnnotations)
        let fresh = pins.map { pin in
            CheckpointAnnotation(
                coordinate: CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lon),
                number: pin.number,
                cost: pin.cost,
                timeMs: pin.timeMs
            )
        }
        mapView.addAnnotations(fresh)

        // Без оффлайн-подложки камеру подгоняем один раз — при первой непустой порции.
        if !coordinator.didSetInitialCamera, !coords.isEmpty || !fresh.isEmpty {
            fitCamera(mapView, coords: coords, annotations: fresh)
            coordinator.didSetInitialCamera = true
        }
    }

    /// Диф стоянок: неизменные аннотации остаются (их выноска не закрывается), уходят и приходят только
    /// изменившиеся. Выбранная стоянка, сменившая длительность (тот же `startMs`), выбирается заново.
    private func updateStopAnnotations(_ mapView: MKMapView) {
        let existing = mapView.annotations.compactMap { $0 as? StopAnnotation }
        let wanted = Set(stopPins)
        let removed = existing.filter { !wanted.contains($0.pin) }
        let selectedStartMs = mapView.selectedAnnotations
            .compactMap { $0 as? StopAnnotation }
            .first { removed.contains($0) }?.pin.startMs
        mapView.removeAnnotations(removed)

        let present = Set(existing.map(\.pin))
        let added = stopPins.filter { !present.contains($0) }.map(StopAnnotation.init)
        mapView.addAnnotations(added)
        if let selectedStartMs, let reselect = added.first(where: { $0.pin.startMs == selectedStartMs }) {
            mapView.selectAnnotation(reselect, animated: false)
        }
    }

    private static func coordinates(_ line: [(lat: Double, lon: Double)]) -> [CLLocationCoordinate2D] {
        line.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    /// Один `MKMultiPolyline` на все [lines] из ≥ 2 точек со стилем [style] (пусто — ничего).
    private func addTrackOverlay(
        _ mapView: MKMapView,
        coordinator: Coordinator,
        lines: [[CLLocationCoordinate2D]],
        style: TrackStrokeStyle
    ) {
        let polylines = lines.filter { $0.count >= 2 }.map { MKPolyline(coordinates: $0, count: $0.count) }
        guard !polylines.isEmpty else { return }
        let multi = MKMultiPolyline(polylines)
        coordinator.strokeStyles[ObjectIdentifier(multi)] = style
        coordinator.trackOverlays.append(multi)
        mapView.addOverlay(multi, level: .aboveLabels)
    }

    // MARK: - Камера

    /// Показать карту гонки: `bounds` файла целиком, но не мельче его `minzoom` — ниже MapKit оверлей
    /// не рисует, и большой файл показал бы одну Apple-карту (тогда в кадре только его центр).
    /// Пока у вида нет размера, кадр откладывается до `layoutSubviews`.
    /// `false` — у файла нет `bounds`, показывать нечего.
    @discardableResult
    private static func frameRaceMap(
        _ mapView: MKMapView,
        metadata: MBTilesMetadata?,
        coordinator: Coordinator,
        animated: Bool
    ) -> Bool {
        guard let bounds = metadata?.bounds else { return false }
        guard mapView.bounds.width > 0 else {
            coordinator.pendingRaceMap = true
            return true
        }
        coordinator.pendingRaceMap = false
        let nw = MKMapPoint(CLLocationCoordinate2D(latitude: bounds.n, longitude: bounds.w))
        let se = MKMapPoint(CLLocationCoordinate2D(latitude: bounds.s, longitude: bounds.e))
        let fileRect = MKMapRect(
            x: min(nw.x, se.x),
            y: min(nw.y, se.y),
            width: max(abs(se.x - nw.x), 1),
            height: max(abs(se.y - nw.y), 1)
        )
        var rect = mapView.mapRectThatFits(fileRect)
        let minZoom = sanitizedZoomRange(minZoom: metadata?.minZoom, maxZoom: metadata?.maxZoom).min
        let maxWidth = maxVisibleMapWidth(viewWidth: mapView.bounds.width, minZoom: minZoom)
        if rect.width > maxWidth {
            let scale = maxWidth / rect.width
            let size = MKMapSize(width: rect.width * scale, height: rect.height * scale)
            rect = MKMapRect(
                origin: MKMapPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                size: size
            )
        }
        mapView.setVisibleMapRect(rect, animated: animated)
        return true
    }

    private func runCameraCommand(_ command: MapCameraCommand, mapView: MKMapView, coordinator: Coordinator) {
        switch command {
        case .raceMap:
            Self.frameRaceMap(mapView, metadata: overlay?.metadata, coordinator: coordinator, animated: true)
        case .myLocation:
            guard let location = mapView.userLocation.location else {
                // Тост меняет состояние SwiftUI — не посреди `updateUIView`.
                let report = onNoLocationFix
                Task { @MainActor in report() }
                return
            }
            // Ближе текущего зума не отдаляем; издалека — на ~1 км.
            let target = MKCoordinateRegion(
                center: location.coordinate,
                latitudinalMeters: 1000,
                longitudinalMeters: 1000
            )
            if mapView.region.span.latitudeDelta > target.span.latitudeDelta {
                mapView.setRegion(target, animated: true)
            } else {
                mapView.setCenter(location.coordinate, animated: true)
            }
        }
    }

    /// Подгонка камеры под трек/пины (когда оффлайн-подложки нет).
    private func fitCamera(
        _ mapView: MKMapView,
        coords: [CLLocationCoordinate2D],
        annotations: [CheckpointAnnotation]
    ) {
        var rect = MKMapRect.null
        for coord in coords {
            let point = MKMapPoint(coord)
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        for annotation in annotations {
            let point = MKMapPoint(annotation.coordinate)
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
        }
        guard !rect.isNull else { return }
        let padding = UIEdgeInsets(top: 48, left: 48, bottom: 48, right: 48)
        mapView.setVisibleMapRect(rect, edgePadding: padding, animated: false)
    }

    // MARK: - Coordinator (MKMapViewDelegate)

    final class Coordinator: NSObject, MKMapViewDelegate {
        var trackOverlays: [MKOverlay] = []
        var strokeStyles: [ObjectIdentifier: TrackStrokeStyle] = [:]
        var stopPins: [MapStopPin] = []
        var didSetInitialCamera = false
        /// Кадр карты гонки ждёт первого `layoutSubviews` (у вида ещё нет размера).
        var pendingRaceMap = false
        var lastRequestId: Int?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            if let line = overlay as? MKMultiPolyline {
                let renderer = MKMultiPolylineRenderer(multiPolyline: line)
                let style = strokeStyles[ObjectIdentifier(line)] ?? .plain
                renderer.strokeColor = style.color
                renderer.lineWidth = style.width
                renderer.lineDashPattern = style.dash
                renderer.lineJoin = .round
                renderer.lineCap = style.dash == nil ? .round : .butt
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is TrackDotAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: TrackDotView.reuseId)
                    ?? TrackDotView(annotation: annotation, reuseIdentifier: TrackDotView.reuseId)
                view.annotation = annotation
                return view
            }
            if annotation is StopAnnotation {
                return mapView.dequeueReusableAnnotationView(
                    withIdentifier: StopAnnotationView.reuseId,
                    for: annotation
                )
            }
            // Синюю точку пользователя рисует MapKit сам.
            guard let cp = annotation as? CheckpointAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: CheckpointAnnotationView.reuseId,
                for: cp
            ) as? CheckpointAnnotationView
            view?.configure(number: cp.number)
            return view
        }
    }
}

// MARK: - Стиль линии трека

/// Стиль `MKMultiPolyline` трека: одноцветный, тёмная подложка под раскраской или штрих скорости.
enum TrackStrokeStyle {
    case plain
    case casing
    case stroke(SpeedStroke)

    var color: UIColor {
        switch self {
        case .plain: UIColor(Color.kolcoOrange)
        case .casing: UIColor(white: 0, alpha: 0.55)
        case .stroke(let stroke): UIColor(stroke.color)
        }
    }

    var width: CGFloat {
        if case .casing = self { return 5 }
        return 3
    }

    var dash: [NSNumber]? {
        if case .stroke(.gap) = self { return [4, 6] }
        return nil
    }
}

// MARK: - Стоянка

/// Стоянка: подпись длительности, выноска «Стоянка 12 мин» / «14:05–14:17».
final class StopAnnotation: NSObject, MKAnnotation {
    let pin: MapStopPin
    let coordinate: CLLocationCoordinate2D

    init(pin: MapStopPin) {
        self.pin = pin
        coordinate = CLLocationCoordinate2D(latitude: pin.lat, longitude: pin.lon)
    }

    var label: String { pin.label }

    var title: String? { "Стоянка \(pin.label)" }

    var subtitle: String? {
        "\(Self.hhmm(pin.startMs))–\(Self.hhmm(pin.endMs))"
    }

    private static func hhmm(_ ms: Int64) -> String {
        formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

/// Тёмная капсула с белой подписью `Font.mono`. Ниже пинов КП по приоритетам — стоянка часто на КП.
final class StopAnnotationView: MKAnnotationView {
    static let reuseId = "track-stop"

    private let label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = true
        displayPriority = .defaultHigh
        zPriority = MKAnnotationViewZPriority(rawValue: MKAnnotationViewZPriority.defaultUnselected.rawValue - 1)
        backgroundColor = UIColor(white: 0.1, alpha: 0.85)
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 1
        label.textColor = .white
        label.font = UIFont(name: "JetBrains Mono", size: 11)
            ?? .monospacedSystemFont(ofSize: 11, weight: .semibold)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var annotation: MKAnnotation? {
        didSet { configure() }
    }

    private func configure() {
        label.text = (annotation as? StopAnnotation)?.label
        label.sizeToFit()
        let size = CGSize(width: label.bounds.width + 10, height: label.bounds.height + 4)
        frame = CGRect(origin: frame.origin, size: size)
        label.frame = CGRect(x: 5, y: 2, width: label.bounds.width, height: label.bounds.height)
        layer.cornerRadius = size.height / 2
    }
}

// MARK: - Точка одиночного фикса трека

/// Одиночный фикс трека (линия из одной точки после фильтра).
final class TrackDotAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }
}

/// Кружок цвета трека, чуть шире полуширины линии — чтобы одиночный фикс был заметен.
final class TrackDotView: MKAnnotationView {
    static let reuseId = "track-dot"
    private static let diameter: CGFloat = 7

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        let d = Self.diameter
        frame = CGRect(x: 0, y: 0, width: d, height: d)
        backgroundColor = UIColor(Color.kolcoOrange)
        layer.cornerRadius = d / 2
        canShowCallout = false
        isEnabled = false
        displayPriority = .required
        zPriority = .min
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

// MARK: - Аннотация КП

/// `MKAnnotation` взятого КП: координата (GPS-фикс взятия) + номер/цена/время для коллаута.
final class CheckpointAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let number: Int
    let cost: Int
    let timeMs: Int64

    init(coordinate: CLLocationCoordinate2D, number: Int, cost: Int, timeMs: Int64) {
        self.coordinate = coordinate
        self.number = number
        self.cost = cost
        self.timeMs = timeMs
    }

    /// Коллаут «КП N · M баллов · HH:mm» (`pointsLabel` для баллов, время из epoch-ms в локальном HH:mm).
    var title: String? {
        "КП \(number) · \(pointsLabel(cost)) · \(Self.hhmm.string(from: Date(timeIntervalSince1970: Double(timeMs) / 1000)))"
    }

    private static let hhmm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}

/// Упрощённый `CPBadge` (без красных лент) как аннотация: кружок `brandRed` с белым номером `Font.mono`.
final class CheckpointAnnotationView: MKAnnotationView {
    static let reuseId = "kp-annotation"
    private static let diameter: CGFloat = 30

    private let label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        let d = Self.diameter
        frame = CGRect(x: 0, y: 0, width: d, height: d)
        backgroundColor = .clear
        canShowCallout = true

        let circle = UIView(frame: bounds)
        circle.backgroundColor = UIColor(Color.brandRed)
        circle.layer.cornerRadius = d / 2
        circle.layer.borderWidth = 2
        circle.layer.borderColor = UIColor.white.cgColor
        circle.isUserInteractionEnabled = false
        addSubview(circle)

        label.frame = circle.bounds
        label.textAlignment = .center
        label.textColor = .white
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        label.font = UIFont(name: "JetBrains Mono", size: 13)
            ?? .monospacedSystemFont(ofSize: 13, weight: .bold)
        circle.addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func configure(number: Int) {
        label.text = "\(number)"
    }
}

/// `MKMapView`, сообщающий о раскладке: кадр по `bounds` файла требует ширину вида,
/// а в `makeUIView` она ещё нулевая.
private final class LayoutAwareMapView: MKMapView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
