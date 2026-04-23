// FCKCRS
// Spec: Specs/features/07-detection-storage.md

import Foundation
import CoreLocation

/// A manually-saved detection event written to disk.
struct DetectionRecord: Identifiable, Codable {

    let id: UUID

    /// When the user tapped "Save".
    var savedAt: Date

    // ── Location ────────────────────────────────────────────────────────
    var latitude: Double
    var longitude: Double
    var locationAccuracy: Double   // metres

    // ── Vehicle ─────────────────────────────────────────────────────────
    var make: String
    var model: String
    var licensePlate: String
    var plateConfidence: Float

    // ── Kinematics ──────────────────────────────────────────────────────
    var speedKmh: Double?
    var heading: String?           // "N", "NE", …

    // ── Provenance ──────────────────────────────────────────────────────
    var detectionMethod: DetectionMethod
    var lidarAvailable: Bool
    var deviceModel: String

    // ── File refs ───────────────────────────────────────────────────────
    /// File names of JPEG snapshots stored alongside this record.
    var snapshots: [String]

    // ── Helpers ─────────────────────────────────────────────────────────

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayTitle: String {
        let vehicle = [make, model].filter { !$0.isEmpty }.joined(separator: " ")
        return vehicle.isEmpty ? "Unknown Vehicle" : vehicle
    }

    static func make(
        from vehicle: DetectedVehicle,
        location: CLLocation?,
        lidarAvailable: Bool,
        snapshots: [String]
    ) -> DetectionRecord {
        DetectionRecord(
            id: UUID(),
            savedAt: Date(),
            latitude:         location?.coordinate.latitude  ?? 0,
            longitude:        location?.coordinate.longitude ?? 0,
            locationAccuracy: location?.horizontalAccuracy   ?? -1,
            make:             vehicle.make,
            model:            vehicle.model,
            licensePlate:     vehicle.licensePlate?.text ?? "",
            plateConfidence:  vehicle.licensePlate?.confidence ?? 0,
            speedKmh:         vehicle.speedKmh,
            heading:          vehicle.heading,
            detectionMethod:  vehicle.detectionMethod,
            lidarAvailable:   lidarAvailable,
            deviceModel:      UIDeviceModelName.current,
            snapshots:        snapshots
        )
    }
}

// MARK: - Device model helper

private enum UIDeviceModelName {
    static var current: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { ptr in
            String(cString: ptr.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }
}
