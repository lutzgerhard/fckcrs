// FCKCRS
// Spec: Specs/features/02-camera-view.md

import SwiftUI
import AVFoundation

struct CameraView: View {

    @EnvironmentObject private var root: ContentViewModel
    var body: some View {
        ZStack {
            // Live camera preview
            CameraPreviewView(session: root.cameraViewModel.cameraService.session)
                .ignoresSafeArea()

            // Detection overlay drawn on top
            DetectionOverlayView(
                displayDetections: root.cameraViewModel.displayDetections,
                mainCar: root.cameraViewModel.mainCar
            )

            // Warmup overlay — fades out once CoreML compilation finishes
            if root.cameraViewModel.isWarmingUp {
                WarmupOverlayView()
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - AVFoundation preview (UIViewRepresentable)

struct CameraPreviewView: UIViewRepresentable {

    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        // session reference doesn't change; nothing to update
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

// MARK: - Warmup overlay

private struct WarmupOverlayView: View {
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 20) {
                // Spinner
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(
                        AngularGradient(
                            gradient: Gradient(colors: [.white.opacity(0.1), .white]),
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .frame(width: 56, height: 56)
                    .rotationEffect(.degrees(rotation))
                    .onAppear {
                        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                            rotation = 360
                        }
                    }

                Text("Initializing")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)

                Text("Loading detection model…")
                    .font(.system(size: 15, design: .rounded))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }
}
