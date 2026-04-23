// FCKCRS
// Spec: Specs/features/04-car-detection.md

@preconcurrency import AVFoundation
import Vision
import CoreML
@preconcurrency import ARKit
import CoreGraphics
import SwiftUI     // withAnimation
import os.log

private let log = Logger(subsystem: "com.fckcrs", category: "VehicleDetection")

// MARK: - Protocol (pluggable detector)

/// Conform to this protocol to add a new detection backend (YOLOv9, RF-DETR, SAM v3, …).
/// Register in `VehicleDetectionService.makeDetector()`.
protocol VehicleDetector: AnyObject, Sendable {
    var name: String { get }
    func detect(in buffer: CMSampleBuffer, arFrame: ARFrame?) async -> [RawDetection]
}

struct RawDetection {
    let boundingBox: CGRect    // normalised 0…1
    let confidence: Float
    let classLabel: String     // e.g. "car", "truck", "person"
    let method: DetectionMethod
    var isVehicle: Bool = true
    var distanceMetres: Double? = nil
    var speedKmh: Double? = nil
    var isApproaching: Bool = false
    /// Stable tracking UUID — nil until this detection is matched to a `DetectedVehicle`.
    var vehicleID: UUID? = nil
    /// True once the matched vehicle has been confirmed across ≥ `confirmationFrames`.
    var isTrackedCar: Bool = false
}

/// Classes treated as primary vehicles (cars, trucks, buses) for topDetection priority.
private let primaryVehicleClasses: Set<String> = ["car", "truck", "bus"]

// MARK: - Service

/// Orchestrates frame delivery, detector selection, tracking, and vision-based kinematics.
@MainActor
final class VehicleDetectionService: ObservableObject {

    // MARK: Published

    @Published var detectedVehicles: [DetectedVehicle] = []
    /// Highest-confidence non-vehicle detection when no vehicles are tracked.
    @Published var topNonVehicle: RawDetection?
    /// All raw detections from the last frame — used by the debug HUD.
    @Published var debugDetections: [RawDetection] = []
    /// The single highest-confidence detection across all classes — drawn with an exact outline.
    /// Primary vehicles (car/truck/bus) are prioritised over other classes.
    @Published var topDetection: RawDetection?
    /// Detections to show bounding boxes for: all vehicle detections, or (if none) all non-vehicle detections.
    @Published var displayDetections: [RawDetection] = []
    /// The closest confirmed car — drives the speed-limit sign in the overlay.
    @Published var mainCar: DetectedVehicle? = nil
    /// Wall-clock seconds for the last YOLO inference pass.
    @Published var lastInferenceSeconds: Double = 0
    /// True while the CoreML model warmup inference is in progress.
    @Published var isWarmingUp: Bool = true

    /// Name of the active detector backend (e.g. "yolov8n-coreml" or "stub").
    var detectorName: String { detector.name }

    // MARK: Config

    /// Target detection rate (Hz).  Frames are dropped if pipeline is slower.
    var targetHz: Double = 5
    private var lastProcessedTime: TimeInterval = 0

    // MARK: Dependencies

    private let plateService: LicensePlateService
    private let detector: VehicleDetector
    private let distanceTracker = CarDistanceTracker()

    // MARK: Tracking state

    private var trackedVehicles: [UUID: DetectedVehicle] = [:]
    private var missedFrames: [UUID: Int] = [:]
    private let maxMissedFrames = 30  // ~3 s at 10 Hz

    // IOU threshold for associating detections to tracks
    private let iouThreshold: Float = 0.3

    // Confirmation threshold (frames)
    private let confirmationFrames = 3
    private var framesSeen: [UUID: Int] = [:]

    // Non-car display stability: keep the same top-3 set for nonCarSwapInterval seconds,
    // but refresh each entry's bounding box every frame so positions track smoothly.
    private var nonCarCache: [RawDetection] = []
    private var nonCarLastSwap: TimeInterval = 0
    private let nonCarSwapInterval: TimeInterval = 2.0

    // Simulator-only heartbeat (no camera frames arrive on the iOS Simulator)
    #if targetEnvironment(simulator)
    private var simTimer: Timer?
    private var simPhase: Double = 0
    #endif

    /// Prevents concurrent YOLO inferences from piling up.
    private var isProcessing = false

    // MARK: Init

    init(plateService: LicensePlateService) {
        self.plateService = plateService
        self.detector = VehicleDetectionService.makeDetector()
        log.info("Using detector: \(self.detector.name)")

        #if targetEnvironment(simulator)
        DispatchQueue.main.async { [weak self] in self?.startSimulatorTimer() }
        #endif
    }

    #if targetEnvironment(simulator)
    private func startSimulatorTimer() {
        simTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.simPhase += 0.05
                let x = CGFloat(0.1 + 0.5 * abs(sin(simPhase)))
                let box = CGRect(x: x, y: 0.2, width: 0.35, height: 0.4)
                let raw = RawDetection(boundingBox: box, confidence: 0.82,
                                       classLabel: "car", method: .stub, isVehicle: true)
                self.debugDetections = [raw]
                withAnimation(.easeInOut(duration: 0.08)) { self.topDetection = raw }
                self.lastInferenceSeconds = 0.042  // simulated timing
                if self.isWarmingUp {
                    withAnimation(.easeInOut(duration: 0.4)) { self.isWarmingUp = false }
                }
                self.applyRawDetections([raw], nonVehicle: nil, intrinsics: nil, timestamp: Date().timeIntervalSinceReferenceDate)
            }
        }
    }
    #endif

    /// Factory — swap here to change the active detector.
    private static func makeDetector() -> VehicleDetector {
        do {
            return try YOLOv8CoreMLDetector()
        } catch {
            log.warning("YOLOv8 model unavailable (\(error.localizedDescription)), falling back to stub")
            return StubVehicleDetector()
        }
    }

    // MARK: - Frame processing

    func process(sampleBuffer: CMSampleBuffer, arFrame: ARFrame?) async {
        guard !isProcessing else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let now = pts.seconds
        let minInterval = 1.0 / targetHz
        guard now - lastProcessedTime >= minInterval else { return }
        lastProcessedTime = now

        isProcessing = true
        defer { isProcessing = false }

        // Extract camera intrinsics before going async
        let intrinsics = CameraIntrinsics.from(sampleBuffer) ?? CameraIntrinsics.fallback

        // ── YOLO inference (background queue inside detector) ────────────────
        let t0 = Date()
        let allDetections = await detector.detect(in: sampleBuffer, arFrame: arFrame)
        lastInferenceSeconds = Date().timeIntervalSince(t0)

        if isWarmingUp {
            withAnimation(.easeInOut(duration: 0.4)) { isWarmingUp = false }
        }

        let vehicleDetections = allDetections.filter(\.isVehicle)
        let topNV = allDetections.filter { !$0.isVehicle }
            .max(by: { $0.confidence < $1.confidence })

        applyRawDetections(vehicleDetections, nonVehicle: topNV, intrinsics: intrinsics, timestamp: now)

        // Attach distance/speed/trackingState from DetectedVehicle to raw detections for HUD and overlay.
        let withDist = allDetections.map { raw -> RawDetection in
            guard raw.isVehicle else { return raw }
            var updated = raw
            if let vehicle = detectedVehicles.first(where: {
                $0.boundingBox.iou(with: raw.boundingBox) > 0.3
            }) {
                updated.distanceMetres = vehicle.distanceMetres
                updated.speedKmh       = vehicle.speedKmh
                updated.isApproaching  = vehicle.isApproaching
                updated.vehicleID      = vehicle.id
                updated.isTrackedCar   = vehicle.isConfirmed
            }
            return updated
        }
        debugDetections = withDist

        // Display: show cars if any exist; otherwise show a stable top-3 non-car set.
        let carDets = withDist.filter(\.isVehicle)
        if carDets.isEmpty {
            let candidates = withDist
                .filter { !$0.isVehicle }
                .sorted { $0.confidence > $1.confidence }

            if nonCarCache.isEmpty || now - nonCarLastSwap >= nonCarSwapInterval {
                // Full swap: pick a fresh top-3 and reset the timer.
                nonCarCache   = Array(candidates.prefix(3))
                nonCarLastSwap = now
            } else {
                // Between swaps: refresh each cached entry's position from the current frame.
                // Match by best IoU first, then by same classLabel; keep stale box if lost.
                nonCarCache = nonCarCache.map { cached -> RawDetection in
                    let byIOU = candidates
                        .filter  { cached.boundingBox.iou(with: $0.boundingBox) > 0.15 }
                        .max(by: { cached.boundingBox.iou(with: $0.boundingBox)
                                 < cached.boundingBox.iou(with: $1.boundingBox) })
                    if let match = byIOU { return match }
                    if let sameClass = candidates.first(where: { $0.classLabel == cached.classLabel }) {
                        return sameClass
                    }
                    return cached   // keep stale position until next full swap
                }
            }
            displayDetections = nonCarCache
        } else {
            // Cars present — reset cache so the next non-car period starts fresh.
            nonCarCache    = []
            nonCarLastSwap = 0
            displayDetections = Array(carDets.sorted { $0.confidence > $1.confidence }.prefix(2))
        }

        // Main car: closest confirmed vehicle (drives the speed-limit sign).
        mainCar = detectedVehicles
            .filter(\.isConfirmed)
            .min { ($0.distanceMetres ?? .infinity) < ($1.distanceMetres ?? .infinity) }

        // Top-1 detection: primary vehicles (car/truck/bus) beat all others,
        // then secondary vehicles, then non-vehicles — within each tier rank by confidence.
        let best = withDist.max(by: { detectionPriority($0) < detectionPriority($1) })
        withAnimation(.easeInOut(duration: 0.08)) { topDetection = best }
    }

    /// Core tracking + publish step.
    private func applyRawDetections(_ rawDetections: [RawDetection],
                                    nonVehicle: RawDetection?,
                                    intrinsics: CameraIntrinsics?,
                                    timestamp: Double) {
        var updated: [UUID: DetectedVehicle] = [:]
        var usedDetections = Set<Int>()

        for (id, existing) in trackedVehicles {
            var bestIdx: Int?
            var bestIOU: Float = iouThreshold

            for (i, raw) in rawDetections.enumerated() where !usedDetections.contains(i) {
                let iou = existing.boundingBox.iou(with: raw.boundingBox)
                if iou > bestIOU {
                    bestIOU = iou
                    bestIdx = i
                }
            }

            if let idx = bestIdx {
                let raw = rawDetections[idx]
                usedDetections.insert(idx)
                missedFrames[id] = 0
                framesSeen[id, default: 0] += 1

                var vehicle = existing
                vehicle.boundingBox = raw.boundingBox
                vehicle.confidence  = raw.confidence
                vehicle.isConfirmed = (framesSeen[id] ?? 0) >= confirmationFrames
                vehicle.lastSeenAt  = Date()

                // Vision-based kinematic estimation
                if let intr = intrinsics,
                   let estimate = distanceTracker.update(
                       vehicleID: id,
                       box: raw.boundingBox,
                       intrinsics: intr,
                       timestamp: timestamp
                   ) {
                    vehicle.distanceMetres = estimate.distanceMetres
                    vehicle.speedKmh       = estimate.speedKmh
                    vehicle.isApproaching  = estimate.isApproaching
                }

                updated[id] = vehicle
            } else {
                let missed = (missedFrames[id] ?? 0) + 1
                missedFrames[id] = missed
                if missed < maxMissedFrames {
                    updated[id] = existing
                } else {
                    distanceTracker.remove(vehicleID: id)
                    missedFrames.removeValue(forKey: id)
                    framesSeen.removeValue(forKey: id)
                }
            }
        }

        // New detections not matched to existing tracks
        for (i, raw) in rawDetections.enumerated() where !usedDetections.contains(i) {
            let newID = UUID()
            let vehicle = DetectedVehicle(
                id: newID,
                boundingBox: raw.boundingBox,
                confidence: raw.confidence,
                isConfirmed: false,
                detectionMethod: raw.method,
                make: "", model: "",
                licensePlate: nil,
                speedKmh: nil, heading: nil, distanceMetres: nil,
                isApproaching: false,
                firstSeenAt: Date(), lastSeenAt: Date()
            )
            updated[newID] = vehicle
            framesSeen[newID] = 1
            missedFrames[newID] = 0
        }

        trackedVehicles = updated
        detectedVehicles = Array(trackedVehicles.values)
            .sorted { $0.confidence > $1.confidence }

        let hasConfirmed = detectedVehicles.contains(where: \.isConfirmed)
        topNonVehicle = hasConfirmed ? nil : nonVehicle
    }

    /// Called by LicensePlateService with a result; merge into tracked vehicle.
    func updatePlate(_ plate: LicensePlate, for vehicleID: UUID) {
        guard var vehicle = trackedVehicles[vehicleID] else { return }
        if plate.confidence > (vehicle.licensePlate?.confidence ?? 0) {
            vehicle.licensePlate = plate
            trackedVehicles[vehicleID] = vehicle
            detectedVehicles = Array(trackedVehicles.values)
                .sorted { $0.confidence > $1.confidence }
        }
    }
}

// MARK: - Detection priority

/// Higher return value = higher priority (used with `max(by:)`).
private func detectionPriority(_ d: RawDetection) -> Double {
    let tier: Double
    if primaryVehicleClasses.contains(d.classLabel) {
        tier = 2.0
    } else if d.isVehicle {
        tier = 1.0
    } else {
        tier = 0.0
    }
    return tier * 10.0 + Double(d.confidence)
}

// MARK: - CGRect IOU helper

private extension CGRect {
    func iou(with other: CGRect) -> Float {
        let intersection = self.intersection(other)
        guard !intersection.isNull else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = (self.width * self.height)
                      + (other.width * other.height)
                      - intersectionArea
        guard unionArea > 0 else { return 0 }
        return Float(intersectionArea / unionArea)
    }
}

// MARK: - Stub detector (simulator / no model)

/// Returns synthetic moving detections so the UI can be developed without a real camera.
final class StubVehicleDetector: VehicleDetector, @unchecked Sendable {

    let name = "stub"

    private var phase: Double = 0

    func detect(in buffer: CMSampleBuffer, arFrame: ARFrame?) async -> [RawDetection] {
        phase += 0.05
        let x = 0.1 + 0.5 * abs(sin(phase))
        let box = CGRect(x: x, y: 0.2, width: 0.35, height: 0.4)
        return [
            RawDetection(boundingBox: box, confidence: 0.82, classLabel: "car", method: .stub)
        ]
    }
}
