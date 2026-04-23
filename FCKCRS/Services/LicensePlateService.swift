// FCKCRS
// Spec: Specs/features/05-license-plate.md

@preconcurrency import AVFoundation
import Vision
import CoreImage
import CoreGraphics
import os.log

private let log = Logger(subsystem: "com.fckcrs", category: "LicensePlate")

// CMSampleBuffer has no Sendable annotation (pre-concurrency AVFoundation type).
// The OCR request uses the buffer read-only; AVFoundation retains it safely.
private struct SendableSampleBuffer: @unchecked Sendable {
    let buffer: CMSampleBuffer
}

/// Runs Vision OCR on vehicle bounding-box crops to extract license plate text.
final class LicensePlateService: @unchecked Sendable {

    // US plate rough regex: 5–8 alphanumeric characters
    private let platePattern = try! NSRegularExpression(pattern: "^[A-Z0-9]{5,8}$")

    private let requestQueue = DispatchQueue(label: "com.fckcrs.plateQueue", qos: .utility)

    // Track consecutive failures per vehicle to stop retrying
    private var consecutiveFailures: [UUID: Int] = [:]
    private let maxFailures = 5

    // MARK: - Public API

    /// Asynchronously recognise a plate in the given sample buffer, cropped to vehicleBox.
    /// Returns nil if no plausible plate found.
    func recognise(
        in sampleBuffer: CMSampleBuffer,
        vehicleBox: CGRect,       // normalised 0…1
        vehicleID: UUID
    ) async -> LicensePlate? {

        let failures = consecutiveFailures[vehicleID] ?? 0
        guard failures < maxFailures else { return nil }

        let wrapped = SendableSampleBuffer(buffer: sampleBuffer)
        return await withCheckedContinuation { continuation in
            requestQueue.async { [self] in
                let result = self.runOCR(on: wrapped.buffer, vehicleBox: vehicleBox, vehicleID: vehicleID)
                continuation.resume(returning: result)
            }
        }
    }

    func resetFailures(for vehicleID: UUID) {
        consecutiveFailures.removeValue(forKey: vehicleID)
    }

    // MARK: - OCR

    private func runOCR(
        on sampleBuffer: CMSampleBuffer,
        vehicleBox: CGRect,
        vehicleID: UUID
    ) -> LicensePlate? {

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return nil
        }

        // Crop to vehicle region
        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let imageSize = CGSize(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer)
        )

        // Vision coordinate system: origin bottom-left; flip Y
        let flippedBox = CGRect(
            x: vehicleBox.minX * imageSize.width,
            y: (1 - vehicleBox.maxY) * imageSize.height,
            width: vehicleBox.width * imageSize.width,
            height: vehicleBox.height * imageSize.height
        )
        let cropped = ciImage.cropped(to: flippedBox)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.05

        let handler = VNImageRequestHandler(ciImage: cropped, options: [:])
        do {
            try handler.perform([request])
        } catch {
            log.error("OCR error: \(error.localizedDescription)")
            consecutiveFailures[vehicleID, default: 0] += 1
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else {
            consecutiveFailures[vehicleID, default: 0] += 1
            return nil
        }

        // Pick best candidate matching plate pattern
        var best: (text: String, confidence: Float, box: CGRect)?

        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let cleaned = candidate.string
                .uppercased()
                .components(separatedBy: .whitespaces).joined()

            let range = NSRange(cleaned.startIndex..., in: cleaned)
            guard platePattern.firstMatch(in: cleaned, range: range) != nil else { continue }

            let conf = candidate.confidence
            if best == nil || conf > best!.confidence {
                best = (cleaned, conf, obs.boundingBox)
            }
        }

        if let hit = best {
            consecutiveFailures[vehicleID] = 0
            return LicensePlate(
                text: hit.text,
                confidence: hit.confidence,
                regionInCrop: hit.box,
                observedAt: Date()
            )
        } else {
            consecutiveFailures[vehicleID, default: 0] += 1
            return nil
        }
    }
}
