// FCKCRS
// Spec: Specs/features/05-license-plate.md

import Foundation
import CoreGraphics

/// The result of an OCR pass on a vehicle crop.
struct LicensePlate: Equatable, Codable {

    /// Recognised plate text (upper-cased, whitespace trimmed).
    var text: String

    /// OCR confidence (0…1).
    var confidence: Float

    /// Bounding box within the vehicle crop (normalised 0…1).
    var regionInCrop: CGRect

    /// Timestamp of this reading.
    var observedAt: Date

    // MARK: Helpers

    /// Returns true if the text looks like a plausible plate (5–8 alphanum chars).
    var isPlausible: Bool {
        let clean = text.components(separatedBy: .whitespaces).joined()
        return clean.count >= 5 &&
               clean.count <= 8 &&
               clean.allSatisfy({ $0.isLetter || $0.isNumber })
    }

    var displayText: String {
        text.isEmpty ? "PLATE?" : text
    }
}
