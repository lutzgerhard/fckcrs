// FCKCRS
// Spec: Specs/features/02-camera-view.md

import SwiftUI

/// Transparent overlay drawn on top of the camera preview.
/// - Shows bounding boxes for all detected cars (white = new, yellow = tracked).
/// - When no cars are detected, shows non-car detections at 50 % opacity instead.
/// - Shows a speed-limit sign in the top-left for the closest confirmed car.
struct DetectionOverlayView: View {

    let displayDetections: [RawDetection]
    let mainCar: DetectedVehicle?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {

                // Subtle dim when something is detected
                if !displayDetections.isEmpty {
                    Color.black.opacity(0.10)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                // Bounding boxes
                ForEach(Array(displayDetections.enumerated()), id: \.element.stableID) { _, det in
                    DetectionBoxView(detection: det, viewSize: geo.size)
                }

                // Speed-limit sign — top-left, only when a tracked car has speed data
                if let car = mainCar, let kmh = car.speedKmh, kmh >= 2.0 {
                    SpeedLimitSign(speedKmh: kmh,
                                   isApproaching: car.isApproaching,
                                   distanceMetres: car.distanceMetres)
                        .padding(.top, 60)
                        .padding(.leading, 12)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: mainCar?.speedKmh.map { Int($0) })
        }
    }
}

// MARK: - Bounding box view (single detection)

private struct DetectionBoxView: View {

    let detection: RawDetection
    let viewSize: CGSize

    @State private var animatedBox: CGRect = .zero

    private var isCar: Bool { detection.isVehicle }

    private var borderColor: Color {
        if !isCar              { return .white }
        if detection.isTrackedCar { return .yellow }
        return .white
    }

    private var elementOpacity: Double { isCar ? 1.0 : 0.5 }

    private var screenBox: CGRect {
        CGRect(x: animatedBox.minX * viewSize.width,
               y: animatedBox.minY * viewSize.height,
               width:  animatedBox.width  * viewSize.width,
               height: animatedBox.height * viewSize.height)
    }

    var body: some View {
        ZStack {
            // Glow
            RoundedRectangle(cornerRadius: 4)
                .stroke(borderColor.opacity(0.35), lineWidth: 14)
                .blur(radius: 7)
                .frame(width: screenBox.width, height: screenBox.height)
                .position(x: screenBox.midX, y: screenBox.midY)
                .opacity(elementOpacity)

            // Border
            RoundedRectangle(cornerRadius: 4)
                .stroke(borderColor, lineWidth: 5)
                .shadow(color: borderColor.opacity(0.9), radius: 6, x: 0, y: 0)
                .frame(width: screenBox.width, height: screenBox.height)
                .position(x: screenBox.midX, y: screenBox.midY)
                .opacity(elementOpacity)

            // Label pill (class + confidence + distance)
            Text(labelText)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.7))
                .cornerRadius(4)
                .shadow(color: borderColor.opacity(0.4), radius: 4, x: 0, y: 0)
                .position(x: screenBox.minX + labelWidth / 2 + 2,
                          y: max(screenBox.minY - 11, 14))
                .opacity(elementOpacity)

            // Inverted speed sign — shown for cars with a valid speed estimate
            if isCar, let kmh = detection.speedKmh, kmh >= 2.0 {
                InvertedSpeedSign(speedKmh: kmh)
                    .position(x: min(max(screenBox.midX, 30), viewSize.width - 30),
                              y: max(screenBox.minY - 46, 46))
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .onAppear { animatedBox = detection.boundingBox }
        .onChange(of: detection.boundingBox) { _, newBox in
            withAnimation(.easeInOut(duration: 0.08)) { animatedBox = newBox }
        }
        .animation(.easeInOut(duration: 0.2), value: detection.speedKmh.map { Int($0) })
    }

    private var labelText: String {
        let conf = Int(detection.confidence * 100)
        var parts = ["\(detection.classLabel.uppercased()) \(conf)%"]
        if let dist = distanceString(detection) { parts.append(dist) }
        if let spd  = speedString(detection)    { parts.append(spd) }
        return parts.joined(separator: " ")
    }

    private var labelWidth: CGFloat { CGFloat(labelText.count) * 7.5 + 14 }
}

// MARK: - Speed-limit sign

private struct SpeedLimitSign: View {

    let speedKmh: Double
    let isApproaching: Bool
    let distanceMetres: Double?

    private var displaySpeed: Int {
        Locale.current.measurementSystem == .metric
            ? Int(speedKmh.rounded())
            : Int((speedKmh * 0.621371).rounded())
    }

    private var unit: String {
        Locale.current.measurementSystem == .metric ? "km/h" : "mph"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Distance badge above the sign
            if let d = distanceMetres {
                Text(d >= 1 ? String(format: "%.0fm", d) : String(format: "%.0fcm", d * 100))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(4)
                    .padding(.bottom, 4)
            }

            // Sign body
            VStack(spacing: 2) {
                Text("\(displaySpeed)")
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .foregroundColor(.black)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(unit)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.black.opacity(0.7))
                    .kerning(1)
            }
            .frame(width: 80, height: 72)
            .background(Color.white)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.black, lineWidth: 3)
            )
            .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
        }
    }
}

// MARK: - Inverted speed sign (per-vehicle, black background)

private struct InvertedSpeedSign: View {

    let speedKmh: Double

    private var displaySpeed: Int {
        Locale.current.measurementSystem == .metric
            ? Int(speedKmh.rounded())
            : Int((speedKmh * 0.621371).rounded())
    }

    private var unit: String {
        Locale.current.measurementSystem == .metric ? "km/h" : "mph"
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("SPEED")
                .font(.system(size: 7, weight: .black))
                .foregroundColor(.white)
                .kerning(1.5)
            Text("LIMIT")
                .font(.system(size: 7, weight: .black))
                .foregroundColor(.white)
                .kerning(1.5)
            Rectangle()
                .fill(Color.white)
                .frame(height: 1)
                .padding(.top, 2)
                .padding(.bottom, 1)
            Text("\(displaySpeed)")
                .font(.system(size: 26, weight: .black, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(unit)
                .font(.system(size: 7, weight: .bold))
                .foregroundColor(.white.opacity(0.7))
                .kerning(0.5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .fixedSize()
        .background(Color.black)
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white, lineWidth: 2))
        .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 2)
    }
}

// MARK: - Distance and speed strings (also used by DebugHUDPanel)

/// Returns a formatted distance string, preferring the Kalman estimate.
func distanceString(_ det: RawDetection) -> String? {
    if let m = det.distanceMetres {
        return m >= 1 ? String(format: "%.1fm", m) : String(format: "%.0fcm", m * 100)
    }
    // Pinhole fallback (no Kalman estimate yet)
    let bw = Float(det.boundingBox.width)
    guard bw > 0.02 else { return nil }
    let refWidth: Float
    switch det.classLabel {
    case "car":              refWidth = 180
    case "truck", "bus":     refWidth = 250
    case "motorcycle":       refWidth = 80
    case "bicycle":          refWidth = 60
    case "person":           refWidth = 50
    case "traffic light":    refWidth = 40
    case "stop sign":        refWidth = 75
    default:                 refWidth = 60
    }
    let cm = Int((0.785 * refWidth) / bw)
    return cm >= 100 ? "~\(cm / 100)m" : "~\(cm)cm"
}

/// Returns a speed string with directional arrow, or nil if speed is unknown/zero.
func speedString(_ det: RawDetection) -> String? {
    guard let kmh = det.speedKmh, kmh >= 2.0 else { return nil }
    let arrow = det.isApproaching ? "↓" : "↑"
    if Locale.current.measurementSystem == .metric {
        return "\(arrow)\(Int(kmh.rounded()))km/h"
    } else {
        return "\(arrow)\(Int((kmh * 0.621371).rounded()))mph"
    }
}

// MARK: - Debug HUD panel

struct DebugHUDPanel: View {

    let detectorName: String
    let detections: [RawDetection]
    let inferenceSeconds: Double

    private var top4: [RawDetection] {
        Array(detections.sorted { $0.confidence > $1.confidence }.prefix(4))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            // Detector name
            Text(detectorName)
                .font(.system(size: 20, weight: .bold, design: .monospaced))
                .foregroundColor(.yellow)

            // Inference time
            Text(String(format: "%.0f ms  ·  %d det",
                        inferenceSeconds * 1000, detections.count))
                .font(.system(size: 20, design: .monospaced))
                .foregroundColor(inferenceSeconds > 0.2 ? .orange : .green)

            Divider()
                .frame(width: 300)
                .background(Color.white.opacity(0.3))

            if detections.isEmpty {
                Text("no detections")
                    .font(.system(size: 20, design: .monospaced))
                    .foregroundColor(.gray)
            } else {
                ForEach(Array(top4.enumerated()), id: \.offset) { _, det in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(det.isVehicle ? Color.red : Color.cyan)
                            .frame(width: 12, height: 12)
                        Text(det.classLabel.uppercased())
                            .font(.system(size: 20, weight: .semibold, design: .monospaced))
                            .foregroundColor(det.isTrackedCar ? .yellow : .white)
                        Spacer(minLength: 0)
                        if let dist = distanceString(det) {
                            Text(dist)
                                .font(.system(size: 20, design: .monospaced))
                                .foregroundColor(det.distanceMetres != nil ? .cyan : .white.opacity(0.5))
                        }
                        if let spd = speedString(det) {
                            Text(spd)
                                .font(.system(size: 20, design: .monospaced))
                                .foregroundColor(det.isApproaching ? .orange : .green)
                        }
                        Text(String(format: "%.0f%%", det.confidence * 100))
                            .font(.system(size: 20, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .frame(width: 300)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.65))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
        )
    }
}

// MARK: - RawDetection stable ID helper

private extension RawDetection {
    /// Stable SwiftUI ForEach identity: vehicleID for tracked cars, composite string for others.
    var stableID: String {
        vehicleID?.uuidString ?? classLabel
    }
}
