// FCKCRS
// Spec: Specs/features/03-map-view.md

import Foundation
import CoreLocation
import Combine

/// Queries the Mapbox Directions API for the `maxspeed` annotation of the road
/// under the user's current location, updating whenever the user moves ≥ 50 m
/// or 15 s have elapsed.
///
/// Requires `MapboxAccessToken` in Info.plist.
/// No SDK needed — plain URLSession calls.
@MainActor
final class SpeedLimitService: ObservableObject {

    @Published var speedLimit: Measurement<UnitSpeed>? = nil

    private let accessToken: String
    private var cancellables = Set<AnyCancellable>()

    private var lastQueryCoord: CLLocationCoordinate2D?
    private var lastQueryTime: Date = .distantPast

    /// Minimum travel distance before re-querying (metres).
    private let reQueryDistance: CLLocationDistance = 50
    /// Minimum time between queries regardless of movement (seconds).
    private let reQueryInterval: TimeInterval = 15

    init(locationService: LocationService) {
        self.accessToken = Bundle.main.object(forInfoDictionaryKey: "MapboxAccessToken") as? String ?? ""
        print("[SpeedLimit] token loaded, empty=\(accessToken.isEmpty)")

        guard !accessToken.isEmpty else {
            print("[SpeedLimit] ⚠️ No Mapbox token — speed limit disabled")
            return
        }

        locationService.$location
            .compactMap { $0 }
            .sink { [weak self] loc in
                Task { @MainActor [weak self] in
                    await self?.maybeQuery(at: loc)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Private

    private func maybeQuery(at location: CLLocation) async {
        let now = Date()
        if let lastCoord = lastQueryCoord {
            let lastLoc = CLLocation(latitude: lastCoord.latitude, longitude: lastCoord.longitude)
            let moved   = location.distance(from: lastLoc)
            let elapsed = now.timeIntervalSince(lastQueryTime)
            guard moved >= reQueryDistance || elapsed >= reQueryInterval else { return }
        }
        lastQueryCoord = location.coordinate
        lastQueryTime  = now

        print("[SpeedLimit] querying at \(location.coordinate.latitude), \(location.coordinate.longitude)")
        let result = await fetch(at: location)
        print("[SpeedLimit] result: \(result.map { "\($0.value) \($0.unit)" } ?? "nil")")
        speedLimit = result
    }

    /// Calls the Mapbox Directions API with the current position and a projected
    /// waypoint 150 m ahead (based on GPS course, north if unavailable).
    /// Returns the `maxspeed` of the first road segment, or nil if unknown.
    private func fetch(at location: CLLocation) async -> Measurement<UnitSpeed>? {
        let course    = location.course > 0 ? location.course : 0
        let rad       = course * .pi / 180
        // 150 m projection gives a long enough segment to reliably carry maxspeed data.
        let latOff    = 150.0 / 111_320.0
        let lonOff    = 150.0 / (111_320.0 * cos(location.coordinate.latitude * .pi / 180))
        let lat2      = location.coordinate.latitude  + latOff * cos(rad)
        let lon2      = location.coordinate.longitude + lonOff * sin(rad)

        let pair1 = "\(location.coordinate.longitude),\(location.coordinate.latitude)"
        let pair2 = "\(lon2),\(lat2)"

        var comps = URLComponents(string: "https://api.mapbox.com/directions/v5/mapbox/driving/\(pair1);\(pair2)")!
        comps.queryItems = [
            .init(name: "annotations",  value: "maxspeed"),
            .init(name: "overview",     value: "full"),
            // "unlimited" snapping radius: snap to nearest road regardless of
            // how far away it is (handles being inside a building / driveway).
            .init(name: "radiuses",     value: "unlimited;unlimited"),
            .init(name: "access_token", value: accessToken),
        ]
        guard let url = comps.url else { return nil }

        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            print("[SpeedLimit] HTTP \(status), body: \(String(data: data, encoding: .utf8)?.prefix(300) ?? "-")")
            guard status == 200 else { return nil }
            let decoded = try JSONDecoder().decode(DirectionsResponse.self, from: data)
            // No route at all — location completely unreachable (no road nearby).
            guard let routes = decoded.routes, !routes.isEmpty else {
                print("[SpeedLimit] no routes in response")
                return nil
            }

            let entry = routes.first?.legs?.first?.annotation?.maxspeed?.first
            print("[SpeedLimit] entry: speed=\(entry?.speed as Any) unit=\(entry?.unit as Any) none=\(entry?.none as Any) unknown=\(entry?.unknown as Any)")

            // Genuinely unlimited road (e.g. de-restricted autobahn) — hide sign.
            if entry?.none == true { return nil }

            // Explicit OSM speed limit.
            if let speed = entry?.speed, let unit = entry?.unit {
                return Measurement(value: Double(speed),
                                   unit: unit == "mph" ? .milesPerHour : .kilometersPerHour)
            }

            // No explicit limit (missing tag, unknown, or empty array) —
            // default to residential 20 mph.
            return Measurement(value: 20, unit: .milesPerHour)
        } catch {
            print("[SpeedLimit] error: \(error)")
            return nil
        }
    }
}

// MARK: - Mapbox Directions response models (private)

private struct DirectionsResponse: Codable {
    let routes: [DRoute]?
}
private struct DRoute: Codable {
    let legs: [DLeg]?
}
private struct DLeg: Codable {
    let annotation: DAnnotation?
}
private struct DAnnotation: Codable {
    let maxspeed: [MaxspeedEntry]?
}
private struct MaxspeedEntry: Codable {
    let speed: Int?
    let unit: String?
    let unknown: Bool?
    let none: Bool?
}
