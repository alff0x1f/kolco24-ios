//
//  PhotoCameraController.swift
//  kolco24
//
//  Прод-контроллер камеры фото-отметки поверх AVFoundation. Порт ПОВЕДЕНИЯ (не структуры)
//  CameraX-части `ui/photo/PhotoCaptureScreen.kt`: одна `AVCaptureSession` с `AVCapturePhotoOutput`,
//  фронт/тыл переключением входа, фонарик (только тыл), гвард от повторного захвата. Ориентация — не
//  ручным поворотом битмапы (как Android `RotationTracker`/`bucketOrientationDegrees` + `targetRotation`),
//  а нативным `AVCaptureDevice.RotationCoordinator` (таргет iOS 18): угол горизонт-левел для превью
//  применяется к соединению превью-слоя, угол для съёмки — к соединению фото-выхода в момент кадра.
//
//  Конкурентность — паттерн Apple AVCam: класс НЕ actor; вся мутация `AVCaptureSession` идёт на
//  выделенной последовательной `sessionQueue`, а наблюдаемое состояние (`@Published`) публикуется на
//  main (ObservableObject публикует на главном потоке). Ссылки на превью-слой/координатор/девайс —
//  main-owned; вход/выход сессии — sessionQueue-owned. `@unchecked Sendable`: аффинити держим дисциплиной.
//
//  Платформенная граница: `import AVFoundation` живёт только под `Audio/` и `Photo/` (grep-инвариант
//  этапа 7). Юнит-тестов нет (камера не работает в симуляторе — device-only); поведенческая логика
//  фото-сессии покрыта `PhotoModelTests`. На симуляторе `AVCaptureDevice.default(...)` возвращает `nil`,
//  все ветки загвардены — краша нет, превью пустое.
//

import AVFoundation
import Combine
import Foundation
import os

/// Разрешение на камеру, экспонируемое рут-вьюхе без её собственного `import AVFoundation`
/// (grep-инвариант: AVFoundation живёт только под `Audio/`/`Photo/`).
enum CameraPermission {
    case authorized
    case denied
    case notDetermined
}

/// Контроллер одной камерной сессии фото-отметки. `ObservableObject` — вьюха (`PhotoCaptureView`)
/// подписывается на фронт/тыл/фонарик/готовность; сама `AVCaptureSession` отдаётся превью-слою.
final class PhotoCameraController: NSObject, ObservableObject, @unchecked Sendable {

    private static let log = Logger(subsystem: "kolco24", category: "PhotoCamera")

    /// Общая сессия, скармливаемая превью-слою (`AVCaptureVideoPreviewLayer`) во вьюхе.
    let session = AVCaptureSession()

    /// Есть ли фронтальная камера (скрывает кнопку переключения, когда её нет — как Android `hasFrontCamera`).
    @Published private(set) var hasFrontCamera = false
    /// Активна фронталка? Драйвит иконку переключения и гейт фонарика (фонарик — только тыл).
    @Published private(set) var isFrontCamera = false
    /// Состояние фонарика (только тыл). Off при переключении на фронталку.
    @Published private(set) var torchOn = false
    /// Гвард повторного захвата: блокирует затвор/«Готово»/«изменить», пока кадр в полёте (зеркало Android `isCapturing`).
    @Published private(set) var isCapturing = false

    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "kolco24.camera.session")

    // sessionQueue-owned
    private var videoInput: AVCaptureDeviceInput?
    private var configured = false

    // main-owned
    private var currentDevice: AVCaptureDevice?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewAngleObservation: NSKeyValueObservation?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var captureCompletion: ((Data?) -> Void)?

    // MARK: - Разрешение (обёртка AVFoundation для рут-вьюхи)

    /// Текущий статус доступа к камере (без прямого касания AVFoundation во вьюхе).
    static var permission: CameraPermission {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    /// Запросить доступ к камере (первое открытие). Возвращает выданность.
    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    // MARK: - Жизненный цикл

    /// Сконфигурировать сессию (вход тыловой камеры + фото-выход) и запустить. Идемпотентна.
    /// Вызывать после выдачи разрешения на камеру. На симуляторе (нет устройства) — тихий no-op.
    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.configureIfNeeded()
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    /// Остановить сессию (закрытие кавера). Безопасно вне main.
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Привязать превью-слой из `UIViewRepresentable` (main): слой получает сессию, `RotationCoordinator`
    /// пересобирается вокруг активного устройства + слоя для горизонт-левел углов (iOS 18).
    func attachPreview(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        layer.session = session
        recreateRotationCoordinator()
    }

    // MARK: - Съёмка

    /// Снять один кадр. Гвардит повторный захват (Android `isCapturing`): пока кадр в полёте — no-op.
    /// Угол горизонт-левел применяется к соединению фото-выхода в момент кадра (на `sessionQueue`).
    /// Колбэк с JPEG `Data` (или `nil` при сбое) приходит на main.
    func capturePhoto(completion: @escaping (Data?) -> Void) {
        guard !isCapturing else { return }
        isCapturing = true
        captureCompletion = completion
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.session.isRunning,
                  let connection = self.photoOutput.connection(with: .video), connection.isActive else {
                DispatchQueue.main.async { self.finishCapture(with: nil) }
                return
            }
            if let angle, connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: - Переключение камеры / фонарик

    /// Фронт ↔ тыл пересборкой входа (Android `isFrontCamera` toggle → rebind).
    func switchCamera() {
        guard !isCapturing else { return }
        let toFront = !isFrontCamera
        sessionQueue.async { [weak self] in self?.rebuildInput(front: toFront) }
    }

    /// Включить/выключить фонарик (только тыл). Off-переключение или отсутствие фонарика — no-op.
    func toggleTorch() {
        guard !isFrontCamera, let device = currentDevice, device.hasTorch else { return }
        let desired = !torchOn
        torchOn = desired
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                device.torchMode = desired ? .on : .off
                device.unlockForConfiguration()
            } catch {
                Self.log.error("Torch toggle failed: \(String(describing: error))")
            }
        }
    }

    // MARK: - Конфигурация сессии (sessionQueue)

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        let hasFront = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
        let device = addInput(front: false)
        session.commitConfiguration()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hasFrontCamera = hasFront
            self.currentDevice = device
            self.recreateRotationCoordinator()
        }
    }

    /// Заменить активный вход на камеру нужной позиции внутри одной транзакции конфигурации.
    private func rebuildInput(front: Bool) {
        session.beginConfiguration()
        if let existing = videoInput {
            session.removeInput(existing)
            videoInput = nil
        }
        let device = addInput(front: front)
        session.commitConfiguration()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isFrontCamera = front
            self.torchOn = false
            self.currentDevice = device
            self.recreateRotationCoordinator()
        }
    }

    /// Добавить вход камеры позиции; при отсутствии устройства (симулятор) — тихий no-op. Возвращает
    /// активное устройство (для main-owned зеркала под фонарик/координатор).
    private func addInput(front: Bool) -> AVCaptureDevice? {
        let position: AVCaptureDevice.Position = front ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
            ?? AVCaptureDevice.default(for: .video) else {
            Self.log.error("No camera device for position \(front ? "front" : "back", privacy: .public)")
            return nil
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                videoInput = input
            }
            return device
        } catch {
            Self.log.error("Failed to build camera input: \(String(describing: error))")
            return nil
        }
    }

    // MARK: - Ориентация (main)

    /// (Пере)собрать `RotationCoordinator` вокруг активного устройства + превью-слоя и подписаться на
    /// KVO угла превью → применяем к соединению слоя.
    private func recreateRotationCoordinator() {
        previewAngleObservation = nil
        guard let device = currentDevice else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyPreviewAngle(coordinator.videoRotationAngleForHorizonLevelPreview)
        previewAngleObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.new]
        ) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            DispatchQueue.main.async { self?.applyPreviewAngle(angle) }
        }
    }

    /// Применить угол горизонт-левел к соединению превью-слоя (main).
    private func applyPreviewAngle(_ angle: CGFloat) {
        if let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    // MARK: - Завершение захвата (main)

    private func finishCapture(with data: Data?) {
        isCapturing = false
        let completion = captureCompletion
        captureCompletion = nil
        completion?(data)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension PhotoCameraController: AVCapturePhotoCaptureDelegate {

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        DispatchQueue.main.async { [weak self] in self?.finishCapture(with: data) }
    }
}
