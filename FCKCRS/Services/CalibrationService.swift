// FCKCRS

import Foundation
import CoreGraphics
import os.log

private let log = Logger(subsystem: "com.fckcrs", category: "CalibrationService")

// MARK: - ConeMarker

struct ConeMarker {
    /// Screen point where the user tapped.
    let screenPoint: CGPoint
    /// Known real-world distance in metres for this marker.
    let knownDistanceMetres: Double
}

// MARK: - CalibrationService

/// Manages a ground-plane calibration workflow that maps screen-tapped cone markers
/// with known distances to a single scale factor used to correct velocity estimates.
@MainActor
final class CalibrationService: ObservableObject {

    // MARK: Published

    @Published var isCalibrating: Bool = false
    /// Up to 3 user-placed cone markers for the current calibration pass.
    @Published var markers: [ConeMarker] = []

    // MARK: State

    /// Multiply any raw distance estimate by this factor to get a calibrated distance.
    private(set) var scaleFactor: Double = 1.0

    /// Staging area: markers collected during the current session, committed on finish.
    private var pendingMarkers: [ConeMarker] = []

    // MARK: - API

    /// Begin a new calibration session.
    func startCalibration() {
        isCalibrating = true
        pendingMarkers = []
        markers = []
        log.info("CalibrationService: started")
    }

    /// Add a cone marker at `point` with `distance` metres.
    /// Automatically finishes calibration when 3 markers have been collected.
    func addMarker(at point: CGPoint, distance: Double) {
        guard isCalibrating else { return }
        let marker = ConeMarker(screenPoint: point, knownDistanceMetres: distance)
        pendingMarkers.append(marker)
        markers = pendingMarkers
        log.info("CalibrationService: added marker \(pendingMarkers.count) at dist \(distance)m")

        if pendingMarkers.count >= 3 {
            finishCalibration()
        }
    }

    /// Commit the current markers and compute the scale factor.
    func finishCalibration() {
        guard !pendingMarkers.isEmpty else {
            isCalibrating = false
            return
        }

        // We need a raw distance proxy for each marker.
        // Use the screen-Y coordinate as a proxy for apparent distance:
        // lower screen Y (closer to top in UIKit) → farther away.
        // We fit: knownDistance ≈ scale * rawProxy, where rawProxy is derived
        // from the screen point.  In the absence of a full projective model here,
        // we use the inverse of the normalised screen-Y (measured from top) as the
        // distance proxy, clamped to avoid division by zero.
        //
        // scale = mean(knownDistance_i / proxy_i)
        //
        // This is a least-squares solution when proxies are independent.

        guard pendingMarkers.count >= 2 else {
            // Only one marker — use its distance directly as a reference,
            // scale = knownDistance / proxy
            let m = pendingMarkers[0]
            let proxy = max(m.screenPoint.y, 1.0)   // raw screen y (larger = lower on screen = closer)
            let rawEstimate = 1.0 / Double(proxy) * 100.0   // arbitrary unit proportional to 1/y
            if rawEstimate > 0 {
                scaleFactor = m.knownDistanceMetres / rawEstimate
            }
            isCalibrating = false
            markers = pendingMarkers
            log.info("CalibrationService: finished with 1 marker, scaleFactor=\(self.scaleFactor)")
            return
        }

        // Least-squares fit using screen-Y proxies and known distances.
        // Model: knownDist_i = scale * (1 / normalised_screen_y_i)
        // In screen coordinates: screenY grows downward. Farther objects appear
        // higher (smaller screenY). Proxy = 1/screenY.
        var sumNumerator: Double = 0
        var sumDenominator: Double = 0
        for m in pendingMarkers {
            let screenY = max(Double(m.screenPoint.y), 1.0)
            let proxy = 1.0 / screenY
            // Least-squares normal equation for scale:
            // scale = Σ(proxy_i * known_i) / Σ(proxy_i²)
            sumNumerator   += proxy * m.knownDistanceMetres
            sumDenominator += proxy * proxy
        }

        if sumDenominator > 1e-12 {
            scaleFactor = sumNumerator / sumDenominator
        }

        isCalibrating = false
        markers = pendingMarkers
        log.info("CalibrationService: finished, scaleFactor=\(self.scaleFactor)")
    }

    /// Discard the in-progress calibration without updating `scaleFactor`.
    func cancelCalibration() {
        pendingMarkers = []
        markers = []
        isCalibrating = false
        log.info("CalibrationService: cancelled")
    }
}
