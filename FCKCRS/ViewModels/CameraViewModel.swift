// FCKCRS
// Spec: Specs/features/02-camera-view.md, 04-car-detection.md

import SwiftUI
import AVFoundation
import ARKit
import UIKit
import Combine

@MainActor
final class CameraViewModel: ObservableObject {

    // MARK: - Published

    @Published var detectedVehicles: [DetectedVehicle] = []
    @Published var topNonVehicle: RawDetection?
    @Published var debugDetections: [RawDetection] = []
    @Published var topDetection: RawDetection?
    @Published var displayDetections: [RawDetection] = []
    @Published var mainCar: DetectedVehicle? = nil
    @Published var lastInferenceSeconds: Double = 0
    @Published var isLiDARActive: Bool = false
    @Published var isWarmingUp: Bool = true

    var trackedVehicleCount: Int { detectedVehicles.filter(\.isConfirmed).count }
    var detectorName: String { detectionService.detectorName }

    // MARK: - Services

    let cameraService = CameraService()
    private let detectionService: VehicleDetectionService
    private let lidar: LiDARService

    // MARK: - Frame capture for annotation / snapshots

    private var latestSampleBuffer: CMSampleBuffer?

    /// Strong reference so the receiver is not deallocated when start() returns.
    /// (CameraService stores consumers as weak references.)
    private var frameReceiver: FrameReceiver?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(detectionService: VehicleDetectionService, lidar: LiDARService) {
        self.detectionService = detectionService
        self.lidar = lidar

        // Bind detection service publications directly so the Simulator timer
        // path (no camera frames) and any future non-frame source also reach
        // the UI without going through the FrameReceiver callback.
        detectionService.$detectedVehicles.assign(to: &$detectedVehicles)
        detectionService.$topNonVehicle.assign(to: &$topNonVehicle)
        detectionService.$debugDetections.assign(to: &$debugDetections)
        detectionService.$topDetection.assign(to: &$topDetection)
        detectionService.$displayDetections.assign(to: &$displayDetections)
        detectionService.$mainCar.assign(to: &$mainCar)
        detectionService.$lastInferenceSeconds.assign(to: &$lastInferenceSeconds)
        detectionService.$isWarmingUp.assign(to: &$isWarmingUp)

        // Drive focus toward the closest confirmed car.
        // Only update when the car's bounding-box centre moves > 5 % in either axis,
        // debounced 200 ms so the lens has time to settle before being redirected.
        let focusPoints = detectionService.$mainCar
            .map { car -> CGPoint in
                guard let box = car?.boundingBox else { return CGPoint(x: 0.5, y: 0.5) }
                return CGPoint(x: box.midX, y: box.midY)
            }
            .removeDuplicates { abs($0.x - $1.x) < 0.05 && abs($0.y - $1.y) < 0.05 }

        focusPoints
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] point in self?.cameraService.setFocusPoint(point) }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func start(plateService: LicensePlateService) async {
        await cameraService.requestPermissionAndStart()

        // Wire camera frames → detection pipeline.
        // Stored on self so CameraService's weak reference doesn't immediately dangle.
        let receiver = FrameReceiver { [weak self] buffer in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.latestSampleBuffer = buffer
                let arFrame = self.lidar.latestFrame
                await self.detectionService.process(sampleBuffer: buffer, arFrame: arFrame)
                // detectedVehicles + topNonVehicle forwarded via Combine (see init)

                // Fire plate recognition for confirmed vehicles
                for vehicle in self.detectedVehicles where vehicle.isConfirmed && vehicle.licensePlate == nil {
                    Task {
                        if let plate = await plateService.recognise(
                            in: buffer,
                            vehicleBox: vehicle.boundingBox,
                            vehicleID: vehicle.id
                        ) {
                            await MainActor.run {
                                self.detectionService.updatePlate(plate, for: vehicle.id)
                                // detectedVehicles forwarded via Combine
                            }
                        }
                    }
                }

                self.isLiDARActive = self.lidar.isRunning
            }
        }
        frameReceiver = receiver
        cameraService.addConsumer(receiver)
    }

    func stop() {
        cameraService.stop()
    }

    // MARK: - Annotated frame for storage

    /// Returns the latest camera frame as a UIImage (no overlays).
    /// The ISP delivers 640×640 crops from the landscape sensor, so the raw
    /// CGImage is in landscape-right orientation. `.right` tells UIKit to
    /// rotate 90° CW when rendering, which matches what the preview layer shows.
    func latestCameraImage() -> UIImage? {
        guard let buffer = latestSampleBuffer,
              let imageBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
    }

    /// Renders current camera frame with detection overlays burned in.
    func currentAnnotatedFrame() -> UIImage? {
        guard let buffer = latestSampleBuffer,
              let imageBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }

        let baseImage = UIImage(cgImage: cgImage)
        let size = baseImage.size

        UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
        defer { UIGraphicsEndImageContext() }

        baseImage.draw(at: .zero)

        let ctx = UIGraphicsGetCurrentContext()!

        for vehicle in detectedVehicles {
            let rect = CGRect(
                x: vehicle.boundingBox.minX * size.width,
                y: vehicle.boundingBox.minY * size.height,
                width: vehicle.boundingBox.width * size.width,
                height: vehicle.boundingBox.height * size.height
            )

            let color: UIColor = vehicle.isConfirmed ? .green : .yellow
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(3)
            ctx.stroke(rect)

            let label = vehicle.makeModel.isEmpty ? "Vehicle" : vehicle.makeModel
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let str = NSAttributedString(string: label, attributes: attrs)
            str.draw(at: CGPoint(x: rect.minX + 4, y: rect.minY - 20))
        }

        return UIGraphicsGetImageFromCurrentImageContext()
    }
}

// MARK: - Frame receiver helper (bridges delegate callback to async)

private final class FrameReceiver: SampleBufferConsumer {
    private let handler: (CMSampleBuffer) -> Void
    init(_ handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
    }
    func receive(sampleBuffer: CMSampleBuffer) {
        handler(sampleBuffer)
    }
}
