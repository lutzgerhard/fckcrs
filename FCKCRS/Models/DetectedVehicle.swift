// FCKCRS
// Spec: Specs/features/04-car-detection.md, 05-license-plate.md, 06-lidar-tracking.md

import Foundation
import CoreGraphics

/// A vehicle currently visible in the camera frame.
struct DetectedVehicle: Identifiable, Equatable {

    /// Stable tracking identifier for this vehicle across frames.
    let id: UUID

    /// Normalised bounding box in camera frame coordinates (0…1 in both axes).
    var boundingBox: CGRect

    /// Detection confidence (0…1).
    var confidence: Float

    /// Tentative until confirmed by N consecutive frames.
    var isConfirmed: Bool

    /// Which pipeline produced this detection.
    var detectionMethod: DetectionMethod

    // ── Make / Model ────────────────────────────────────────────────────

    var make: String   // "" = unknown
    var model: String  // "" = unknown

    // ── License Plate ───────────────────────────────────────────────────

    var licensePlate: LicensePlate?

    // ── LiDAR / Kinematics ──────────────────────────────────────────────

    /// Estimated speed in km/h from Kalman-filtered geometric distance.  nil until tracked.
    var speedKmh: Double?

    /// Cardinal/intercardinal heading string: "N", "NE", "E", …
    var heading: String?

    /// Distance from camera in metres (geometric/Kalman).  nil until first estimate.
    var distanceMetres: Double?

    /// True when the vehicle is moving toward the camera (positive radial velocity).
    var isApproaching: Bool

    // ── Timestamps ──────────────────────────────────────────────────────

    var firstSeenAt: Date
    var lastSeenAt: Date

    // ── Helpers ─────────────────────────────────────────────────────────

    var makeModel: String {
        switch (make.isEmpty, model.isEmpty) {
        case (false, false): return "\(make) \(model)"
        case (false, true):  return make
        case (true, false):  return model
        default:             return "Unknown Vehicle"
        }
    }

    var speedDisplay: String? {
        guard let s = speedKmh else { return nil }
        if s < 1 { return "stationary" }
        if Locale.current.measurementSystem == .metric {
            return "~\(Int(s.rounded())) km/h"
        } else {
            return "~\(Int((s * 0.621371).rounded())) mph"
        }
    }
}

// MARK: - Supporting enums

enum DetectionMethod: String, Codable {
    case lidar      = "lidar"
    case vision     = "vision"
    case coreml     = "coreml"
    case stub       = "stub"
}
