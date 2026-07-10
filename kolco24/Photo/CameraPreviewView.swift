//
//  CameraPreviewView.swift
//  kolco24
//
//  SwiftUI-обёртка `AVCaptureVideoPreviewLayer` для экрана фото-отметки. Живёт под `Photo/`, потому что
//  касается AVFoundation (grep-инвариант этапа 7: `import AVFoundation` только под `Audio/`/`Photo/`) —
//  рут-вьюха `PhotoCaptureView` рендерит её, не импортируя AVFoundation.
//
//  Слой привязывается к сессии контроллера (`attachPreview`), который вокруг него строит
//  `RotationCoordinator` и применяет горизонт-левел углы (device-only; в симуляторе превью пустое).
//

import AVFoundation
import SwiftUI

/// Живое превью камеры: `UIView`, чей backing-layer — `AVCaptureVideoPreviewLayer`, привязанный к
/// сессии контроллера.
struct CameraPreview: UIViewRepresentable {
    let controller: PhotoCameraController

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        controller.attachPreview(view.videoPreviewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    /// `UIView`, у которого layer-класс — `AVCaptureVideoPreviewLayer` (canonical camera-preview idiom).
    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
