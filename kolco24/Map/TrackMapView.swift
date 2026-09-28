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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.register(
            CheckpointAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: CheckpointAnnotationView.reuseId
        )
        mapView.register(StopAnnotationView.self, forAnnotationViewWithReuseIdentifier: StopAnnotationView.reuseId)

        // Оффлайн-подложка добавляется ОДИН раз (при наличии) — Apple-тайлы тогда не грузятся.
        if let overlay {
            let tileOverlay = MBTilesOverlay(metadata: overlay.metadata, tileData: overlay.tileData)
            mapView.addOverlay(tileOverlay, level: .aboveLabels)
            // Флаг ставим ТОЛЬКО если камера реально спозиционирована по bounds. Без валидных
            // bounds `applyOverlayCamera` возвращает false → падаем в `applyData`, где камера
            // подгоняется под трек/пины (иначе карта открылась бы в дефолтном регионе с данными
            // команды за кадром).
            if applyOverlayCamera(mapView, metadata: overlay.metadata) {
                context.coordinator.didSetInitialCamera = true
            }
        }

        applyData(mapView, coordinator: context.coordinator)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        applyData(mapView, coordinator: context.coordinator)
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

    /// Камера под оффлайн-подложку: регион по `bounds`, `cameraBoundary` по bbox, `cameraZoomRange`
    /// из зумов метаданных (аппроксимация зум→дистанция — device-only, без тестов).
    /// Возвращает `true`, только если камера реально спозиционирована (есть валидные `bounds`);
    /// `false` → вызывающий должен подогнать камеру под трек/пины.
    @discardableResult
    private func applyOverlayCamera(_ mapView: MKMapView, metadata: MBTilesMetadata?) -> Bool {
        guard let bounds = metadata?.bounds else { return false }
        let centerLat = (bounds.s + bounds.n) / 2
        let centerLon = (bounds.w + bounds.e) / 2
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.001, abs(bounds.n - bounds.s)),
            longitudeDelta: max(0.001, abs(bounds.e - bounds.w))
        )
        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: span
        )
        mapView.setRegion(region, animated: false)

        let nw = MKMapPoint(CLLocationCoordinate2D(latitude: bounds.n, longitude: bounds.w))
        let se = MKMapPoint(CLLocationCoordinate2D(latitude: bounds.s, longitude: bounds.e))
        let rect = MKMapRect(
            x: min(nw.x, se.x),
            y: min(nw.y, se.y),
            width: abs(se.x - nw.x),
            height: abs(se.y - nw.y)
        )
        mapView.cameraBoundary = MKMapView.CameraBoundary(mapRect: rect)

        // Зумы санируем в 0…22 (`Core/Map`), min > max → дефолты — те же значения, что и в оверлее.
        let zoom = sanitizedZoomRange(minZoom: metadata?.minZoom, maxZoom: metadata?.maxZoom)
        // zoom→дистанция камеры (грубо): ширина мира на зуме z ≈ circ·cos(lat)/2^z.
        let minDistance = cameraDistance(forZoom: zoom.max, latitude: centerLat)
        let maxDistance = cameraDistance(forZoom: zoom.min, latitude: centerLat)
        if let range = MKMapView.CameraZoomRange(
            minCenterCoordinateDistance: minDistance,
            maxCenterCoordinateDistance: maxDistance
        ) {
            mapView.setCameraZoomRange(range, animated: false)
        }
        return true
    }

    /// Грубая оценка `centerCoordinateDistance` для зума `z` на широте `latitude`.
    private func cameraDistance(forZoom z: Int, latitude: Double) -> Double {
        let earthCircumference = 40_075_016.686 // метры по экватору
        let latRad = latitude * .pi / 180
        return earthCircumference * cos(latRad) / pow(2.0, Double(z))
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
