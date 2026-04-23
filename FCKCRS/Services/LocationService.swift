// FCKCRS
// Spec: Specs/features/03-map-view.md

import CoreLocation
import Combine

@MainActor
final class LocationService: NSObject, ObservableObject {

    // MARK: - Published

    @Published var location: CLLocation?
    @Published var heading: CLHeading? = nil
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published var isDenied: Bool = false

    // MARK: - Private

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 5   // update every 5 m
        // Heading filter: only fire delegate when bearing changes ≥ 3°.
        // CLLocationManager fuses magnetometer + gyroscope (IMU) internally.
        manager.headingFilter = 3
    }

    func requestPermissionAndStart() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
            manager.startUpdatingHeading()
        default:
            isDenied = true
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.location = loc
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateHeading newHeading: CLHeading) {
        Task { @MainActor in self.heading = newHeading }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.startUpdatingLocation()
                manager.startUpdatingHeading()
                self.isDenied = false
            case .denied, .restricted:
                self.isDenied = true
            default:
                break
            }
        }
    }
}
