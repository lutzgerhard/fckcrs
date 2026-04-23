// FCKCRS
// Spec: Specs/features/02-camera-view.md

@preconcurrency import AVFoundation
import UIKit

/// Manages the AVFoundation capture session and vends sample buffers
/// to registered consumers.
///
/// Not @MainActor — AVCaptureSession runs on a private capture queue.
/// @Published mutations are explicitly dispatched to MainActor.
final class CameraService: NSObject, ObservableObject, @unchecked Sendable {

    // MARK: - Published state

    @Published var isRunning: Bool = false
    @Published var authorizationStatus: AVAuthorizationStatus = .notDetermined

    // MARK: - Internal

    let session = AVCaptureSession()

    private let captureQueue = DispatchQueue(label: "com.fckcrs.captureQueue",
                                             qos: .userInitiated)
    private var videoOutput: AVCaptureVideoDataOutput?
    private var captureDevice: AVCaptureDevice?

    /// Set after configure() completes; used by ContentViewModel to trigger saves.
    private(set) var rollingClipRecorder: RollingClipRecorder?

    /// Frame delivery callbacks (weak to avoid retain cycles).
    private var consumers: [WeakSampleBufferConsumer] = []

    // MARK: - Setup

    @MainActor
    func requestPermissionAndStart() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        let updated = AVCaptureDevice.authorizationStatus(for: .video)
        authorizationStatus = updated
        if updated == .authorized {
            await configureAndStart()
        }
    }

    @MainActor
    func stop() {
        let s = session
        captureQueue.async {
            s.stopRunning()
        }
        isRunning = false
    }

    // MARK: - Focus control

    /// Directs continuous autofocus (and auto-exposure) to the given point.
    ///
    /// `portraitPoint` is normalised (0…1) in portrait screen space
    /// (origin top-left, y increases downward), matching YOLO bounding-box coords.
    ///
    /// The back camera sensor is landscape-right, so the coordinate transform is:
    ///   sensor.x = 1 − portrait.y   (portrait top  → landscape right edge)
    ///   sensor.y =     portrait.x   (portrait left → landscape top edge)
    func setFocusPoint(_ portraitPoint: CGPoint) {
        guard let device = captureDevice else { return }
        captureQueue.async {
            guard device.isFocusPointOfInterestSupported,
                  device.isFocusModeSupported(.continuousAutoFocus) else { return }

            let sx = max(0, min(1, 1.0 - portraitPoint.y))
            let sy = max(0, min(1, portraitPoint.x))
            let sensorPoint = CGPoint(x: sx, y: sy)

            guard (try? device.lockForConfiguration()) != nil else { return }
            device.focusPointOfInterest = sensorPoint
            device.focusMode = .continuousAutoFocus
            if device.isExposurePointOfInterestSupported,
               device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = sensorPoint
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        }
    }

    // MARK: - Consumer registration

    func addConsumer(_ consumer: SampleBufferConsumer) {
        consumers.removeAll { $0.value == nil }
        consumers.append(WeakSampleBufferConsumer(consumer))
    }

    // MARK: - Private

    @MainActor
    private func configureAndStart() async {
        let running: Bool = await withCheckedContinuation { continuation in
            captureQueue.async { [self] in
                self.configure()
                self.session.startRunning()
                continuation.resume(returning: self.session.isRunning)
            }
        }
        isRunning = running
    }

    private func configure() {
        session.beginConfiguration()
        // hd1280x720 gives a sharp preview layer while still allowing the ISP
        // to scale detection buffers down to 640×640 in hardware (see videoSettings below).
        session.sessionPreset = .hd1280x720

        // Input
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                    for: .video,
                                                    position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        captureDevice = device

        // 2× optical-quality zoom + 30 fps cap — one lock covers both.
        // 30 fps halves ISP/USB bandwidth vs 60 fps, giving the ANE and CPU
        // more thermal headroom during extended sessions.
        if (try? device.lockForConfiguration()) != nil {
            let zoom: CGFloat = 2.0
            device.videoZoomFactor = min(max(zoom, device.minAvailableVideoZoomFactor),
                                         device.maxAvailableVideoZoomFactor)
            let fps30 = CMTime(value: 1, timescale: 30)
            device.activeVideoMinFrameDuration = fps30
            device.activeVideoMaxFrameDuration = fps30
            device.unlockForConfiguration()
        }

        // Output
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            // Ask the ISP to deliver exactly 640×640 buffers in hardware.
            // This matches YOLOv8n's native input size so VNCoreMLRequest / Vision
            // performs zero resize — no CPU or GPU scaling work before inference.
            // On iPhone 16 Pro Max the ISP center-crops the 1280×720 source to
            // 720×720 and then scales to 640×640, entirely off the CPU.
            kCVPixelBufferWidthKey as String:  640,
            kCVPixelBufferHeightKey as String: 640
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        videoOutput = output

        // Enable intrinsic matrix delivery so CarDistanceTracker can extract
        // focal length and principal point from each sample buffer.
        if let connection = output.connection(with: .video),
           connection.isCameraIntrinsicMatrixDeliverySupported {
            connection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }

        // ── Rolling-clip recording output (native 1280×720, NV12) ─────────
        let recorder        = RollingClipRecorder()
        let recordingOutput = AVCaptureVideoDataOutput()
        recordingOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        recordingOutput.alwaysDiscardsLateVideoFrames = true
        recordingOutput.setSampleBufferDelegate(recorder, queue: recorder.callbackQueue)

        if session.canAddOutput(recordingOutput) {
            session.addOutput(recordingOutput)
            rollingClipRecorder = recorder
        }

        session.commitConfiguration()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        for wrapper in consumers {
            wrapper.value?.receive(sampleBuffer: sampleBuffer)
        }
    }
}

// MARK: - Protocols & helpers

protocol SampleBufferConsumer: AnyObject {
    func receive(sampleBuffer: CMSampleBuffer)
}

private final class WeakSampleBufferConsumer {
    weak var value: SampleBufferConsumer?
    init(_ v: SampleBufferConsumer) { value = v }
}
