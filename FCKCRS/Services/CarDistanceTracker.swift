// FCKCRS
// Spec: Specs/features/06-lidar-tracking.md
//
// Vision-based per-vehicle distance and speed estimation.
//
// Method: ground-plane pinhole geometry using the camera's intrinsic matrix.
//   d = fy_portrait * cameraHeight / (yBottomPx - cy_portrait)
//
// The intrinsic matrix attachment is already calibrated for the 640×640 output
// buffer (including any videoZoomFactor). Vision rotates the buffer 90° CCW
// (.right orientation) so we remap landscape→portrait with a swap + flip:
//   fx_p = fy_l,  fy_p = fx_l
//   cx_p = cy_l,  cy_p = 640 − cx_l
//
// Per-vehicle state is tracked with a 2-state linear Kalman filter:
//   x = [distance_m, velocity_m/s]   F = [[1,dt],[0,1]]

import AVFoundation
import CoreMedia
import CoreGraphics
import simd
import os.log

private let log = Logger(subsystem: "com.fckcrs", category: "CarDistanceTracker")

// MARK: - CameraIntrinsics

struct CameraIntrinsics {
    /// Focal lengths and principal point in portrait pixel coordinates
    /// (matching the Vision-oriented 640×640 buffer).
    let fx: Double
    let fy: Double
    let cx: Double
    let cy: Double

    /// Extract from a CMSampleBuffer that has the intrinsic-matrix attachment.
    /// Returns nil if the attachment is absent (simulator, or delivery not enabled).
    static func from(_ buffer: CMSampleBuffer) -> CameraIntrinsics? {
        guard let attachment = CMGetAttachment(
            buffer,
            key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
            attachmentModeOut: nil
        ) as? Data else { return nil }

        var matrix = matrix_float3x3()
        guard attachment.count == MemoryLayout<matrix_float3x3>.size else { return nil }
        attachment.withUnsafeBytes { ptr in
            matrix = ptr.load(as: matrix_float3x3.self)
        }

        // CoreMedia matrix is column-major.
        // columns.0 = first column → [fx_l, 0, 0]
        // columns.1 = second column → [0, fy_l, 0]
        // columns.2 = third column  → [cx_l, cy_l, 1]
        let fx_l = Double(matrix.columns.0.x)
        let fy_l = Double(matrix.columns.1.y)
        let cx_l = Double(matrix.columns.2.x)
        let cy_l = Double(matrix.columns.2.y)

        // kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix is calibrated for
        // the actual output buffer size (640×640 here), so no pixel-space scaling
        // is needed. The current videoZoomFactor is already baked into the focal
        // lengths by the camera system — no explicit zoom correction required.
        //
        // The 640×640 buffer arrives in landscape-right orientation. Vision uses
        // .right (90° CCW rotation) to display in portrait. For a square buffer
        // the remapping is a simple swap + flip:
        //   portrait fx = landscape fy   (horizontal ↔ vertical swap)
        //   portrait fy = landscape fx
        //   portrait cx = landscape cy
        //   portrait cy = 640 − landscape cx   (flip across the 640-px axis)
        let fx_p = fy_l
        let fy_p = fx_l
        let cx_p = cy_l
        let cy_p = 640.0 - cx_l

        return CameraIntrinsics(fx: fx_p, fy: fy_p, cx: cx_p, cy: cy_p)
    }

    /// Fallback intrinsics used only when the CMSampleBuffer attachment is absent
    /// (e.g. simulator). Approximate values for the iPhone wide camera at 2× zoom,
    /// 640×640 output: effective horiz FOV ≈ 32° → f ≈ 640/(2·tan 16°) ≈ 1115 px.
    static var fallback: CameraIntrinsics {
        let f = 1000.0
        return CameraIntrinsics(fx: f, fy: f, cx: 320.0, cy: 320.0)
    }
}

// MARK: - Kalman state

private struct KalmanState {
    var d: Double       // distance estimate (m)
    var v: Double       // velocity estimate (m/s, positive = approaching)
    var pdd: Double     // covariance d-d
    var pdv: Double     // covariance d-v
    var pvv: Double     // covariance v-v
    var lastTimestamp: Double   // seconds

    // Process noise parameters (white-noise acceleration model)
    static let sigmaMeasurement: Double = 0.8   // measurement noise std dev (m)
    static let sigmaAccel:       Double = 1.5   // acceleration std dev (m/s²)
}

// MARK: - CarDistanceTracker

/// Maintains per-vehicle Kalman filter state and exposes
/// `update(vehicleID:box:intrinsics:timestamp:)`.
final class CarDistanceTracker {

    /// Assumed camera mounting height above road surface (metres).
    /// Typical dashboard-mount or held-phone position.
    var cameraHeight: Double = 1.35

    private var states: [UUID: KalmanState] = [:]

    // MARK: - Update

    struct KinematicEstimate {
        let distanceMetres: Double
        let speedKmh: Double
        /// True if vehicle is approaching (positive relative velocity toward camera)
        let isApproaching: Bool
    }

    /// Feed a new YOLO bounding box for a vehicle and get back the Kalman-filtered
    /// distance and speed estimate.
    ///
    /// - Parameters:
    ///   - vehicleID: Stable tracking UUID from `VehicleDetectionService`.
    ///   - box: Normalised bounding box (0…1) in **top-left** origin coordinates.
    ///   - intrinsics: Camera intrinsics in portrait/640-px space.
    ///   - timestamp: Monotonic timestamp in seconds (e.g. from `CMSampleBufferGetPresentationTimeStamp`).
    /// - Returns: Kinematic estimate, or nil if geometry is degenerate.
    func update(
        vehicleID: UUID,
        box: CGRect,
        intrinsics: CameraIntrinsics,
        timestamp: Double
    ) -> KinematicEstimate? {

        // ── Geometric distance measurement ────────────────────────────────────
        // Use the bottom edge of the bounding box as the ground contact point.
        let yBottomNorm = Double(box.maxY)                      // 0…1, top-left origin
        let yBottomPx   = yBottomNorm * 640.0                   // pixels in 640-px frame
        let dy = yBottomPx - intrinsics.cy                      // signed offset from principal point

        // Guard: contact point must be below the horizon (dy > 0).
        // A small minimum avoids division blowup when the box is near the image centre.
        guard dy > 10.0 else {
            states.removeValue(forKey: vehicleID)
            return nil
        }

        let measuredDistance = intrinsics.fy * cameraHeight / dy
        guard measuredDistance > 0, measuredDistance < 200 else {
            states.removeValue(forKey: vehicleID)
            return nil
        }

        // ── Kalman filter ─────────────────────────────────────────────────────
        if var state = states[vehicleID] {
            let dt = max(timestamp - state.lastTimestamp, 0.01)
            state.lastTimestamp = timestamp

            // Predict
            let d_pred  = state.d + state.v * dt
            let v_pred  = state.v
            let q       = KalmanState.sigmaAccel * KalmanState.sigmaAccel * dt * dt
            let pdd_pred = state.pdd + 2.0 * state.pdv * dt + state.pvv * dt * dt + q
            let pdv_pred = state.pdv + state.pvv * dt
            let pvv_pred = state.pvv + q / (dt * dt)    // scale Q for velocity row

            // Update
            let R   = KalmanState.sigmaMeasurement * KalmanState.sigmaMeasurement
            let S   = pdd_pred + R
            let kd  = pdd_pred / S
            let kv  = pdv_pred / S
            let innovation = measuredDistance - d_pred

            state.d   = d_pred + kd * innovation
            state.v   = v_pred + kv * innovation
            state.pdd = (1.0 - kd) * pdd_pred
            state.pdv = pdv_pred - kd * pdv_pred
            state.pvv = pvv_pred - kv * pdv_pred

            states[vehicleID] = state

            let speedKmh = abs(state.v) * 3.6
            return KinematicEstimate(
                distanceMetres: max(state.d, 0.1),
                speedKmh: speedKmh,
                isApproaching: state.v > 0
            )
        } else {
            // Initialise state from first measurement
            let initial = KalmanState(
                d: measuredDistance,
                v: 0.0,
                pdd: 25.0,  // uncertain distance (±5m std dev)
                pdv: 0.0,
                pvv: 4.0,   // uncertain velocity (±2 m/s std dev)
                lastTimestamp: timestamp
            )
            states[vehicleID] = initial
            return KinematicEstimate(
                distanceMetres: measuredDistance,
                speedKmh: 0.0,
                isApproaching: false
            )
        }
    }

    /// Remove tracking state for a vehicle that left the frame.
    func remove(vehicleID: UUID) {
        states.removeValue(forKey: vehicleID)
    }

    /// Remove all tracking state.
    func clear() {
        states.removeAll()
    }
}
