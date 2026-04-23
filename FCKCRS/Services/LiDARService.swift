// FCKCRS
// Spec: Specs/features/06-lidar-tracking.md

@preconcurrency import ARKit
import Combine
import CoreGraphics

/// Manages an ARKit world-tracking session to provide LiDAR depth data
/// and camera pose for velocity estimation.
///
/// Falls back to `isAvailable = false` on non-LiDAR devices; the rest of the
/// pipeline continues normally without speed/distance data.
@MainActor
final class LiDARService: NSObject, ObservableObject {

    // MARK: - Public state

    @Published var isAvailable: Bool = false
    @Published var isRunning: Bool = false

    /// Latest ARFrame — consumed by VehicleDetectionService for depth sampling.
    @Published var latestFrame: ARFrame?

    // MARK: - Private

    private let session = ARSession()

    // Velocity tracking: trackingID → circular buffer of (worldPoint, timestamp)
    private var positionHistory: [UUID: [(position: SIMD3<Float>, time: TimeInterval)]] = [:]
    private let historyWindowSize = 10

    // EMA alpha for speed smoothing (spec: 0.3)
    private let emaAlpha: Double = 0.3
    private var smoothedSpeed: [UUID: Double] = [:]

    // MARK: - Lifecycle

    override init() {
        super.init()
        isAvailable = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        session.delegate = self
    }

    func start() {
        guard isAvailable else { return }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth]
        config.worldAlignment = .gravityAndHeading   // heading-aware for compass direction
        session.run(config, options: [.removeExistingAnchors])
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        session.pause()
        isRunning = false
    }

    // MARK: - Depth sampling

    /// Sample the depth at a normalised point (0…1) in the current frame.
    /// Returns distance in metres, or nil if unavailable.
    func depth(at normalisedPoint: CGPoint, in frame: ARFrame) -> Float? {
        guard let depthMap = frame.sceneDepth?.depthMap else { return nil }
        let width  = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let x = Int(normalisedPoint.x * CGFloat(width))
        let y = Int(normalisedPoint.y * CGFloat(height))
        guard x >= 0 && x < width && y >= 0 && y < height else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let baseAddress = CVPixelBufferGetBaseAddress(depthMap)!
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let ptr = baseAddress.advanced(by: y * bytesPerRow + x * MemoryLayout<Float32>.size)
        let depth = ptr.load(as: Float32.self)
        return depth.isNaN || depth.isInfinite ? nil : depth
    }

    // MARK: - Velocity estimation

    /// Update tracking history for a vehicle centroid pixel + depth.
    /// Returns (speedKmh, headingString) or nil if insufficient data.
    func updateAndEstimateVelocity(
        vehicleID: UUID,
        centrePixel: CGPoint,
        depth: Float,
        in frame: ARFrame
    ) -> (speedKmh: Double, heading: String)? {

        let worldPoint = unproject(pixel: centrePixel, depth: depth, frame: frame)
        let entry = (position: worldPoint, time: frame.timestamp)

        var history = positionHistory[vehicleID] ?? []
        history.append(entry)
        if history.count > historyWindowSize { history.removeFirst() }
        positionHistory[vehicleID] = history

        guard history.count >= 2 else { return nil }

        // Compute average velocity from consecutive displacements
        var totalDisplacement = SIMD3<Float>(0, 0, 0)
        var totalTime: Double = 0
        for i in 1..<history.count {
            totalDisplacement += history[i].position - history[i-1].position
            totalTime += history[i].time - history[i-1].time
        }
        guard totalTime > 0 else { return nil }

        let velocityMs = SIMD3<Double>(
            Double(totalDisplacement.x),
            Double(totalDisplacement.y),
            Double(totalDisplacement.z)
        ) / totalTime

        // Horizontal speed only (ignore vertical)
        let horizontalSpeed = sqrt(velocityMs.x * velocityMs.x + velocityMs.z * velocityMs.z)
        let speedKmh = horizontalSpeed * 3.6

        // Clamp to spec bounds
        guard speedKmh <= 300 else { return nil }

        // EMA smoothing
        let prev = smoothedSpeed[vehicleID] ?? speedKmh
        let smoothed = emaAlpha * speedKmh + (1 - emaAlpha) * prev
        smoothedSpeed[vehicleID] = smoothed

        // Heading from velocity x-z components (ARKit: x=right, z=backward in world)
        let heading = headingString(dx: velocityMs.x, dz: velocityMs.z)

        return (speedKmh: smoothed, heading: heading)
    }

    func clearHistory(for vehicleID: UUID) {
        positionHistory.removeValue(forKey: vehicleID)
        smoothedSpeed.removeValue(forKey: vehicleID)
    }

    // MARK: - Helpers

    private func unproject(pixel: CGPoint, depth: Float, frame: ARFrame) -> SIMD3<Float> {
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]

        // Camera-space point
        let xC = (Float(pixel.x) - cx) * depth / fx
        let yC = (Float(pixel.y) - cy) * depth / fy
        let cameraPoint = SIMD4<Float>(xC, yC, -depth, 1)

        // Transform to world space
        let worldTransform = frame.camera.transform
        let worldPoint4 = worldTransform * cameraPoint
        return SIMD3<Float>(worldPoint4.x, worldPoint4.y, worldPoint4.z)
    }

    private func headingString(dx: Double, dz: Double) -> String {
        // ARKit world: +x = east, -z = north (when worldAlignment = .gravityAndHeading)
        let angleDeg = atan2(dx, -dz) * 180 / .pi
        let normalised = (angleDeg + 360).truncatingRemainder(dividingBy: 360)
        let directions = ["N","NE","E","SE","S","SW","W","NW"]
        let index = Int((normalised + 22.5) / 45) % 8
        return directions[index]
    }
}

// MARK: - ARSessionDelegate

extension LiDARService: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor in
            self.latestFrame = frame
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.isRunning = false
        }
    }
}
