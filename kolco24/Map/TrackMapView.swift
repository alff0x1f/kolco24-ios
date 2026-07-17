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
//  пар `Double` lat/lon (`trackPath`/`MapMarkPin`), которые готовит `MapModel`.
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
    /// Точки трека парами `Double` (уже отфильтрованы/отсортированы в `MapModel`).
    let trackPath: [(lat: Double, lon: Double)]
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

        // Оффлайн-подложка добавляется ОДИН раз (при наличии) — Apple-тайлы тогда не грузятся.
        if let overlay {
            let tileOverlay = MBTilesOverlay(metadata: overlay.metadata, tileData: overlay.tileData)
            mapView.addOverlay(tileOverlay, level: .aboveLabels)
            applyOverlayCamera(mapView, metadata: overlay.metadata)
            context.coordinator.didSetInitialCamera = true
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
        // Полилиния: снять старую, положить новую.
        if let old = coordinator.polyline {
            mapView.removeOverlay(old)
            coordinator.polyline = nil
        }
        let coords = trackPath.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        if coords.count >= 2 {
            let line = MKPolyline(coordinates: coords, count: coords.count)
            mapView.addOverlay(line, level: .aboveLabels)
            coordinator.polyline = line
        }

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

    // MARK: - Камера

    /// Камера под оффлайн-подложку: регион по `bounds`, `cameraBoundary` по bbox, `cameraZoomRange`
    /// из зумов метаданных (аппроксимация зум→дистанция — device-only, без тестов).
    private func applyOverlayCamera(_ mapView: MKMapView, metadata: MBTilesMetadata?) {
        guard let bounds = metadata?.bounds else { return }
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

        if let minZoom = metadata?.minZoom, let maxZoom = metadata?.maxZoom, minZoom <= maxZoom {
            // zoom→дистанция камеры (грубо): ширина мира на зуме z ≈ circ·cos(lat)/2^z.
            let minDistance = cameraDistance(forZoom: maxZoom, latitude: centerLat)
            let maxDistance = cameraDistance(forZoom: minZoom, latitude: centerLat)
            if let range = MKMapView.CameraZoomRange(
                minCenterCoordinateDistance: minDistance,
                maxCenterCoordinateDistance: maxDistance
            ) {
                mapView.setCameraZoomRange(range, animated: false)
            }
        }
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
        var polyline: MKPolyline?
        var didSetInitialCamera = false

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tileOverlay = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tileOverlay)
            }
            if let line = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: line)
                renderer.strokeColor = UIColor(Color.kolcoOrange)
                renderer.lineWidth = 3
                renderer.lineJoin = .round
                renderer.lineCap = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
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
