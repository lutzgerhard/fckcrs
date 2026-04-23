// FCKCRS
// Spec: Specs/features/03-map-view.md

import MapKit
import CoreLocation
import Combine

@MainActor
final class MapViewModel: ObservableObject {

    @Published var region: MKCoordinateRegion
    @Published var userLocation: CLLocation?
    @Published var isDenied: Bool = false
    @Published var speedLimit: Measurement<UnitSpeed>? = nil

    // Initial region — San Francisco; overwritten on first location fix
    private static let defaultRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        latitudinalMeters: 400,
        longitudinalMeters: 400
    )

    private let locationService: LocationService
    private var cancellables = Set<AnyCancellable>()

    /// How far the user must move before the map re-centres (metres).
    private let recentreThreshold: CLLocationDistance = 10
    init(locationService: LocationService, speedLimitService: SpeedLimitService) {
        self.locationService = locationService
        self.region = Self.defaultRegion

        // Map re-centring
        locationService.$location
            .compactMap { $0 }
            .sink { [weak self] loc in self?.handleLocationUpdate(loc) }
            .store(in: &cancellables)

        locationService.$isDenied
            .assign(to: &$isDenied)

        speedLimitService.$speedLimit
            .assign(to: &$speedLimit)
    }

    // MARK: - Private

    private func handleLocationUpdate(_ loc: CLLocation) {
        let prev = userLocation?.coordinate
        userLocation = loc

        if let prev {
            let prevLoc = CLLocation(latitude: prev.latitude, longitude: prev.longitude)
            guard loc.distance(from: prevLoc) >= recentreThreshold else { return }
        }
        region = MKCoordinateRegion(
            center: loc.coordinate,
            latitudinalMeters: 400,
            longitudinalMeters: 400
        )
    }

}
