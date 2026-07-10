//
//  PhotoCaptureView.swift
//  kolco24
//
//  Полноэкранный экран съёмки фото-отметки — резервный способ взять КП, когда чип не читается.
//  Порт ПОВЕДЕНИЯ `ui/photo/PhotoCaptureScreen.kt`: мультикадровая сессия, лента миниатюр с удалением,
//  «Готово (N)», фронт/тыл, фонарик, шапка «КП NN» (+ «изменить» в attach-режиме), диалог «Удалить
//  снимки?» при выходе с кадрами, заглушка при отказе в доступе к камере. Драйвит `PhotoModel`
//  (доменный редьюсер) + `PhotoCameraController` (AVFoundation-адаптер из `Photo/`).
//
//  Ориентация — нативным `RotationCoordinator` (в контроллере), не ручным поворотом. Системный звук
//  затвора играет `AVCapturePhotoOutput`; подтверждение записи кадра — SwiftUI-хаптика
//  (`.sensoryFeedback` по счётчику кадров, best-effort). Камера — device-only (в симуляторе превью
//  пустое, кадров нет); поведенческая логика фото-сессии покрыта `PhotoModelTests`.
//
//  Живёт flat в `kolco24/` (как прочие вьюхи); AVFoundation-касания (превью-слой, разрешение) вынесены
//  в `Photo/` (grep-инвариант этапа 7: этот фреймворк импортируется только под `Audio/`/`Photo/`).
//  Ссылка в Настройки — через `@Environment(\.openURL)` схемой `app-settings:` (без UIKit-константы
//  `openSettingsURLString`).
//

import SwiftUI
import UIKit

struct PhotoCaptureView: View {
    let model: PhotoModel
    /// attach-режим (доклейка к недавнему взятию) — показывает «изменить» в шапке.
    let attach: Bool

    @StateObject private var camera = PhotoCameraController()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// Миниатюры, снятые в этой сессии, keyed по относительному пути (совпадает с `model.frames`).
    /// Держим локально из захваченных байт — так вьюхе не нужен резолвер абсолютных путей.
    @State private var thumbnails: [String: UIImage] = [:]
    @State private var permission: CameraPermission = PhotoCameraController.permission
    @State private var showDiscardConfirm = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch permission {
            case .authorized:
                CameraPreview(controller: camera).ignoresSafeArea()
            case .denied:
                deniedPlaceholder
            case .notDetermined:
                Color.black
            }

            VStack(spacing: 0) {
                topBar
                Spacer()
                if permission == .authorized {
                    bottomControls
                }
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: model.frameCount)
        .statusBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            permission = PhotoCameraController.permission
            if permission == .notDetermined {
                permission = await PhotoCameraController.requestAccess() ? .authorized : .denied
            }
            if permission == .authorized { camera.start() }
        }
        .onDisappear { camera.stop() }
        .confirmationDialog(
            "Удалить снимки?",
            isPresented: $showDiscardConfirm,
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                model.discard()
                dismiss()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Снятые кадры (\(model.frameCount)) не будут сохранены.")
        }
    }

    // MARK: - Верхняя панель

    private var topBar: some View {
        HStack(spacing: 4) {
            Button(action: handleBack) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            Text("КП \(String(format: "%02d", model.cpNumber))")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
            if attach {
                Button("изменить") {
                    thumbnails.removeAll()
                    model.changeCheckpoint()
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.leading, 4)
                .disabled(camera.isCapturing)
            }
            Spacer()
            if permission == .authorized && !camera.isFrontCamera {
                Button(action: camera.toggleTorch) {
                    Image(systemName: camera.torchOn ? "bolt.fill" : "bolt.slash.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Нижние контролы (лента + переключение/затвор/готово)

    private var bottomControls: some View {
        VStack(spacing: 12) {
            if !model.frames.isEmpty {
                thumbnailStrip
            }
            HStack {
                // Левый слот балансирует «Готово»; иконка переключения — здесь, если есть фронталка.
                ZStack {
                    if camera.hasFrontCamera {
                        Button(action: camera.switchCamera) {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .disabled(camera.isCapturing)
                    }
                }
                .frame(width: 72, height: 72)

                Spacer()
                shutterButton
                Spacer()

                Button(action: commit) {
                    Text("Готово (\(model.frameCount))")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(model.frameCount > 0 ? .white : .white.opacity(0.4))
                        .frame(width: 72)
                }
                .disabled(model.frameCount == 0 || camera.isCapturing)
            }
            .padding(.horizontal, 24)
        }
        .padding(.bottom, 16)
    }

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.frames, id: \.self) { path in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let image = thumbnails[path] {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                            } else {
                                Color.charcoal
                            }
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        Button { delete(path) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(.black.opacity(0.55)))
                        }
                        .padding(2)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private var shutterButton: some View {
        Button(action: capture) {
            ZStack {
                Circle()
                    .fill(camera.isCapturing ? Color.white.opacity(0.5) : Color.white)
                    .frame(width: 68, height: 68)
                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                    .frame(width: 78, height: 78)
            }
        }
        .disabled(camera.isCapturing)
    }

    private var deniedPlaceholder: some View {
        VStack(spacing: 12) {
            Text("Нужен доступ к камере")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
            Text("Чтобы сфотографировать КП, разрешите доступ к камере в настройках приложения.")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button("Открыть настройки") {
                if let url = URL(string: "app-settings:") { openURL(url) }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 46)
            .background(Color.kolcoOrange)
            .clipShape(RoundedRectangle(cornerRadius: DS.ctaRadius))
            .padding(.top, 8)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Действия

    /// Затвор: снимаем кадр → пишем через модель (диск вне main) → добавляем локальную миниатюру.
    /// Гвард повторного захвата держит контроллер; битый кадр (`writeFrame`==nil) не попадает в ленту.
    private func capture() {
        camera.capturePhoto { data in
            guard let data else { return }
            Task {
                let before = model.frames.count
                await model.addFrame(jpegData: data)
                if model.frames.count > before, let path = model.frames.last {
                    thumbnails[path] = downscaledThumb(data)
                }
            }
        }
    }

    private func delete(_ path: String) {
        guard let index = model.frames.firstIndex(of: path) else { return }
        model.removeFrame(at: index)
        thumbnails[path] = nil
    }

    private func commit() {
        model.commit() // ставит closeRequested; кавер закрывает PhotoFlowView (наблюдатель в MarksView)
    }

    /// Назад/крестик: без кадров — просто закрыть кавер; с кадрами — спросить «Удалить снимки?».
    private func handleBack() {
        guard !camera.isCapturing else { return }
        if model.frames.isEmpty {
            dismiss()
        } else {
            showDiscardConfirm = true
        }
    }

    /// Уменьшить захваченный JPEG до маленькой миниатюры ленты (память + скролл), best-effort.
    private func downscaledThumb(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        let target: CGFloat = 128
        let maxSide = max(image.size.width, image.size.height)
        guard maxSide > target else { return image }
        let scale = target / maxSide
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
