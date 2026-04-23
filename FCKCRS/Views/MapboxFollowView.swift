// FCKCRS
// Mapbox Standard 3D follow-puck view with fused bearing.
//
// A Coordinator monitors speed via its own CLLocationManager and switches the
// Mapbox viewport between two modes — no custom LocationProvider needed:
//   speed > 7 km/h  →  .course  (GPS direction of travel, magnetometer-immune)
//   speed < 3 km/h  →  .heading (compass trueHeading, declination-corrected)
// Hysteresis between 3–7 km/h prevents rapid toggling at stoplights.

import MapboxMaps
import CoreLocation
import UIKit
import SwiftUI

struct MapboxFollowView: UIViewRepresentable {
    typealias UIViewType = MapboxMaps.MapView

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MapboxMaps.MapView {
        let mapView = MapboxMaps.MapView(frame: CGRect.zero)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let standardURI = StyleURI(rawValue: "mapbox://styles/mapbox/standard")!
        mapView.mapboxMap.loadStyle(standardURI)

        // Start in heading (compass) mode for when the app launches while stationary.
        var locationOptions = LocationOptions()
        locationOptions.puckType = .puck2D(Puck2DConfiguration.makeDefault(showBearing: true))
        locationOptions.puckBearing = .heading
        locationOptions.puckBearingEnabled = true
        mapView.location.options = locationOptions

        applyViewport(to: mapView, useCourse: false)

        context.coordinator.mapView = mapView
        context.coordinator.startTracking()

        return mapView
    }

    func updateUIView(_ uiView: MapboxMaps.MapView, context: Context) {}

    // MARK: - Helpers

    static func applyViewport(to mapView: MapboxMaps.MapView, useCourse: Bool) {
        let bearing: FollowPuckViewportStateBearing = useCourse ? .course : .heading

        var opts = mapView.location.options
        opts.puckBearing = useCourse ? .course : .heading
        mapView.location.options = opts

        let followOptions = FollowPuckViewportStateOptions(
            padding: UIEdgeInsets.zero,
            zoom: 17.5,
            bearing: bearing,
            pitch: 60
        )
        let state = mapView.viewport.makeFollowPuckViewportState(options: followOptions)
        mapView.viewport.transition(
            to: state,
            transition: mapView.viewport.makeImmediateViewportTransition()
        )
    }

    private func applyViewport(to mapView: MapboxMaps.MapView, useCourse: Bool) {
        MapboxFollowView.applyViewport(to: mapView, useCourse: useCourse)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, CLLocationManagerDelegate {

        weak var mapView: MapboxMaps.MapView?

        private let manager = CLLocationManager()

        // Hysteresis: switch to course only above high threshold, back below low threshold.
        private let thresholdHigh: CLLocationSpeed = 7.0 / 3.6   // ~7 km/h → course
        private let thresholdLow:  CLLocationSpeed = 3.0 / 3.6   // ~3 km/h → heading
        private var usingCourse = false

        override init() {
            super.init()
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
            manager.headingFilter = 2
        }

        func startTracking() {
            manager.startUpdatingLocation()
            manager.startUpdatingHeading()
        }

        // MARK: CLLocationManagerDelegate

        func locationManager(_ manager: CLLocationManager,
                             didUpdateLocations locations: [CLLocation]) {
            guard let loc = locations.last else { return }
            let speed = max(0, loc.speed)

            let shouldUseCourse: Bool
            if usingCourse {
                shouldUseCourse = speed >= thresholdLow  && loc.course >= 0
            } else {
                shouldUseCourse = speed >= thresholdHigh && loc.course >= 0
            }

            guard shouldUseCourse != usingCourse else { return }
            usingCourse = shouldUseCourse

            DispatchQueue.main.async { [weak self] in
                guard let self, let mapView = self.mapView else { return }
                MapboxFollowView.applyViewport(to: mapView, useCourse: self.usingCourse)
            }
        }

        /// Returning true allows iOS to show the figure-8 calibration prompt
        /// whenever the magnetometer accuracy degrades.
        func locationManagerShouldDisplayHeadingCalibration(
            _ manager: CLLocationManager) -> Bool { true }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            // Permission already granted by the app's LocationService.
        }
    }
}
