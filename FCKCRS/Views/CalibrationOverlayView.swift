// FCKCRS

import SwiftUI

// MARK: - CalibrationOverlayView

/// Transparent calibration overlay shown above the camera preview.
/// Guides the user to tap 3 vehicles at known distances to calibrate
/// the ground-plane distance estimator.
struct CalibrationOverlayView: View {

    @ObservedObject var calibrationService: CalibrationService

    /// Called when the user taps a distance button; provides the tap point in
    /// the view's coordinate space and the chosen distance in metres.
    var onMarkerAdded: (CGPoint, Double) -> Void

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dim background (non-interactive)
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                VStack(spacing: 0) {
                    // ── Top banner ────────────────────────────────────────────
                    topBanner
                    Spacer()
                    // ── Distance buttons ──────────────────────────────────────
                    distanceButtons(center: CGPoint(x: geo.size.width / 2,
                                                    y: geo.size.height / 2))
                        .padding(.bottom, 48)
                }

                // ── Marker circles ────────────────────────────────────────────
                ForEach(Array(calibrationService.markers.enumerated()), id: \.offset) { idx, marker in
                    markerCircle(marker: marker, index: idx, viewSize: geo.size)
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Subviews

    private var topBanner: some View {
        ZStack(alignment: .topTrailing) {
            // Banner text
            VStack(spacing: 4) {
                Text("Calibration Mode")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                Text("Tap a distance button to mark a vehicle at that distance")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.8))
                    .multilineTextAlignment(.center)

                // Marker progress indicator
                HStack(spacing: 8) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(i < calibrationService.markers.count ? Color.green : Color.white.opacity(0.3))
                            .frame(width: 10, height: 10)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 56)
            .padding(.bottom, 16)
            .background(Color.black.opacity(0.75))

            // Action buttons row
            HStack {
                // Done button (top-left)
                Button("Done") {
                    calibrationService.finishCalibration()
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(calibrationService.markers.count >= 2 ? .white : .white.opacity(0.3))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.white.opacity(calibrationService.markers.count >= 2 ? 0.2 : 0.05))
                .cornerRadius(8)
                .disabled(calibrationService.markers.count < 2)
                .padding(.leading, 16)
                .padding(.top, 56)

                Spacer()

                // Cancel button (top-right)
                Button("Cancel") {
                    calibrationService.cancelCalibration()
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.red.opacity(0.6))
                .cornerRadius(8)
                .padding(.trailing, 16)
                .padding(.top, 56)
            }
        }
    }

    private func distanceButtons(center: CGPoint) -> some View {
        HStack(spacing: 16) {
            ForEach([10.0, 20.0, 30.0], id: \.self) { distance in
                Button {
                    onMarkerAdded(center, distance)
                } label: {
                    Text("\(Int(distance))m")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(width: 72, height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.green.opacity(0.75))
                                .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 2)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.5), lineWidth: 1)
                        )
                }
            }
        }
    }

    private func markerCircle(marker: ConeMarker, index: Int, viewSize: CGSize) -> some View {
        let pos = marker.screenPoint

        return ZStack {
            Circle()
                .fill(Color.green.opacity(0.25))
                .frame(width: 50, height: 50)
            Circle()
                .stroke(Color.green, lineWidth: 3)
                .frame(width: 50, height: 50)
            VStack(spacing: 1) {
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .black))
                    .foregroundColor(.white)
                Text("\(Int(marker.knownDistanceMetres))m")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.green)
            }
        }
        .position(x: pos.x, y: pos.y)
        .shadow(color: .black.opacity(0.5), radius: 3, x: 0, y: 1)
        .transition(.scale(scale: 0.5).combined(with: .opacity))
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: calibrationService.markers.count)
    }
}
