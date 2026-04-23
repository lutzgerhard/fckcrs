// FCKCRS
// Spec: Specs/features/03-map-view.md

import SwiftUI
import CoreLocation

struct MapView: View {

    @EnvironmentObject private var root: ContentViewModel

    private var vm: MapViewModel { root.mapViewModel }

    var body: some View {
        if vm.isDenied {
            locationDeniedOverlay
        } else {
            ZStack(alignment: .topLeading) {
                MapboxFollowView()
                    .ignoresSafeArea(edges: .bottom)

                if let limit = vm.speedLimit {
                    RoadSpeedLimitSign(limit: limit)
                        .padding(.top, 10)
                        .padding(.leading, 10)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: vm.speedLimit.map { Int($0.value) })
        }
    }

    // MARK: - Permission denied overlay

    private var locationDeniedOverlay: some View {
        VStack(spacing: 12) {
            Image(systemName: "location.slash.fill")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("Location access required")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            Button("Open Settings") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.blue)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

// MARK: - Road speed limit sign (US-style)

private struct RoadSpeedLimitSign: View {

    let limit: Measurement<UnitSpeed>

    private var displaySpeed: Int {
        let converted = Locale.current.measurementSystem == .metric
            ? limit.converted(to: .kilometersPerHour)
            : limit.converted(to: .milesPerHour)
        return Int(converted.value.rounded())
    }

    private var unit: String {
        Locale.current.measurementSystem == .metric ? "km/h" : "mph"
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("SPEED")
                .font(.system(size: 8, weight: .black))
                .foregroundColor(.black)
                .kerning(1.5)
            Text("LIMIT")
                .font(.system(size: 8, weight: .black))
                .foregroundColor(.black)
                .kerning(1.5)
            Rectangle()
                .fill(Color.black)
                .frame(height: 1.5)
                .padding(.top, 3)
                .padding(.bottom, 2)
            Text("\(displaySpeed)")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundColor(.black)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(unit)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.black.opacity(0.65))
                .kerning(0.5)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .fixedSize()
        .background(Color.white)
        .cornerRadius(7)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.black, lineWidth: 2.5))
        .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
    }
}
