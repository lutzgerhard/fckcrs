// FCKCRS

@preconcurrency import ARKit
import simd
import os.log

private let log = Logger(subsystem: "com.fckcrs", category: "ARVelocityEstimator")

// MARK: - VelocityEstimate

struct VelocityEstimate {
    /// 3-D world position of the vehicle's ground contact point (ARKit world coords).
    var worldPosition: simd_float3
    /// Ground-plane speed in km/h.
    var speedKmh: Double
    /// True when the filtered velocity vector points toward the camera.
    var isApproaching: Bool
    /// Horizontal velocity vector (vx, vz) in m/s in ARKit world coordinates.
    var velocityVector: simd_float2
}

// MARK: - ARVelocityEstimator

/// Maps Vision bounding boxes onto the ARKit world ground plane via ray-casting
/// and tracks per-vehicle velocity with a 4-state Kalman filter.
final class ARVelocityEstimator: @unchecked Sendable {

    // MARK: Config

    /// Assumed camera height above the road surface (metres).
    /// Overridden by CalibrationService when a calibration is available.
    var cameraHeight: Double = 1.35

    // MARK: Private

    private let kalman = VelocityKalmanFilter()
    private let lock = NSLock()

    // MARK: - Public API

    /// Update velocity estimate for a vehicle.
    ///
    /// - Parameters:
    ///   - vehicleID: Stable tracking UUID.
    ///   - bbox:      Normalised CGRect in Vision-portrait space (top-left origin, after .right rotation applied by VNImageRequestHandler).
    ///   - arFrame:   Current ARFrame from ARSession.
    ///   - timestamp: Monotonic timestamp (seconds, e.g. frame PTS).
    /// - Returns: `VelocityEstimate` when a ground-plane intersection is found, otherwise `nil`.
    func update(vehicleID: UUID,
                bbox: CGRect,
                arFrame: ARFrame,
                timestamp: Double) -> VelocityEstimate? {

        // ── Step 1: bbox bottom-centre in portrait space ─────────────────────
        // bbox is in Vision portrait space: x = left→right, y = top→bottom, normalised 0-1.
        // bottom-centre of box:
        let bx_p = bbox.midX                   // horizontal centre in portrait
        let by_p = bbox.maxY                   // bottom edge in portrait

        // Convert portrait → landscape (UIDeviceOrientation.landscapeRight matches .right handler)
        // In portrait: x runs across the short axis, y down the long axis.
        // Landscape pixel: lx = 1 - by_p, ly = bx_p
        let lx = 1.0 - by_p                   // normalised x in landscape image
        let ly = bx_p                          // normalised y in landscape image

        // ── Step 2: Scale to camera pixel coords ────────────────────────────
        let imgRes = arFrame.camera.imageResolution  // e.g. 1920×1440
        let px_cam = Double(lx) * Double(imgRes.width)
        let py_cam = Double(ly) * Double(imgRes.height)

        // ── Step 3: Unproject to camera-space ray ────────────────────────────
        // ARKit intrinsics: 3×3 column-major simd_float3x3
        // Columns: intrinsics[0]=(fx,0,0), [1]=(0,fy,0), [2]=(cx,cy,1)
        let intr = arFrame.camera.intrinsics
        let fx = Double(intr[0][0])
        let fy = Double(intr[1][1])
        let cx = Double(intr[2][0])
        let cy = Double(intr[2][1])

        guard fx > 0, fy > 0 else {
            log.warning("ARKit intrinsics invalid (fx=\(fx) fy=\(fy))")
            return nil
        }

        // Ray in camera space (camera looks toward -Z in ARKit/OpenGL convention)
        let rCam = simd_normalize(simd_float3(
            Float((px_cam - cx) / fx),
            Float(-(py_cam - cy) / fy),
            -1.0
        ))

        // ── Step 4: Transform ray to world space ─────────────────────────────
        let camTransform = arFrame.camera.transform  // 4×4 column-major
        // Upper-3×3 rotation: columns 0,1,2
        let rot = simd_float3x3(
            simd_float3(camTransform[0][0], camTransform[0][1], camTransform[0][2]),
            simd_float3(camTransform[1][0], camTransform[1][1], camTransform[1][2]),
            simd_float3(camTransform[2][0], camTransform[2][1], camTransform[2][2])
        )
        let rWorld = simd_normalize(rot * rCam)

        // Camera world position
        let camPos = simd_float3(
            camTransform[3][0],
            camTransform[3][1],
            camTransform[3][2]
        )

        // ── Step 5: Ray-plane intersection with ground plane y = groundY ─────
        let groundY = Double(camPos.y) - cameraHeight
        let originY = Double(camPos.y)
        let dirY = Double(rWorld.y)

        guard abs(dirY) > 1e-6 else { return nil }   // ray nearly parallel to ground

        let t = (groundY - originY) / dirY
        guard t > 0.5 && t < 200 else { return nil }  // sanity bounds

        let worldPos = simd_float3(
            camPos.x + Float(t) * rWorld.x,
            Float(groundY),
            camPos.z + Float(t) * rWorld.z
        )

        // ── Step 6: Feed into Kalman filter ─────────────────────────────────
        lock.lock()
        let estimate = kalman.update(
            id: vehicleID,
            measuredPX: Double(worldPos.x),
            measuredPZ: Double(worldPos.z),
            timestamp: timestamp
        )
        lock.unlock()

        // ── Step 7: Build result ─────────────────────────────────────────────
        let speedMS = estimate.speedMS
        let speedKmh = speedMS * 3.6

        // isApproaching: velocity vector toward camera projected on XZ plane
        // Camera-forward on XZ = worldPos - camPos projected to XZ, normalised
        let toCamX = Double(camPos.x) - estimate.px
        let toCamZ = Double(camPos.z) - estimate.pz
        let toCamLen = sqrt(toCamX * toCamX + toCamZ * toCamZ)
        let isApproaching: Bool
        if toCamLen > 0.1 {
            let dot = estimate.vx * (toCamX / toCamLen) + estimate.vz * (toCamZ / toCamLen)
            isApproaching = dot > 0
        } else {
            isApproaching = false
        }

        return VelocityEstimate(
            worldPosition: worldPos,
            speedKmh: speedKmh,
            isApproaching: isApproaching,
            velocityVector: simd_float2(Float(estimate.vx), Float(estimate.vz))
        )
    }

    func remove(vehicleID: UUID) {
        lock.lock()
        kalman.remove(id: vehicleID)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        kalman.clear()
        lock.unlock()
    }
}
