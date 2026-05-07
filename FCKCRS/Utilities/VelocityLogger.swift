// FCKCRS

import Foundation
import os.log

private let vlog = Logger(subsystem: "com.fckcrs", category: "VelocityLogger")

// MARK: - LogEntry

struct LogEntry: Codable {
    /// Unix timestamp (seconds since 1970).
    let timestamp: Double
    /// Camera pose as 16 column-major floats (4×4 transform matrix).
    let cameraPose: [Float]
    /// Target 3-D world position [x, y, z] in ARKit world coordinates.
    let target3DPos: [Float]
    /// YOLO bounding box [x, y, w, h] normalised 0-1.
    let yoloBox: [Double]
    /// Calculated speed in km/h.
    let calculatedSpeedKmh: Double
    /// Stable vehicle tracking UUID string.
    let vehicleID: String
}

// MARK: - VelocityLogger

/// Actor-based logger that accumulates `LogEntry` values in memory and flushes them
/// to `Documents/FCKCRS_Clips/manifest.json` periodically or on demand.
actor VelocityLogger {

    static let shared = VelocityLogger()

    // MARK: Config

    private let autoFlushThreshold = 50

    // MARK: State

    private var buffer: [LogEntry] = []

    private var manifestURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let clipsDir = docs.appendingPathComponent("FCKCRS_Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
        return clipsDir.appendingPathComponent("manifest.json")
    }()

    // MARK: - Public API

    /// Append a log entry to the in-memory buffer.
    /// Automatically triggers a flush every `autoFlushThreshold` entries.
    func log(_ entry: LogEntry) {
        buffer.append(entry)
        if buffer.count >= autoFlushThreshold {
            Task { await self.flush() }
        }
    }

    /// Write the buffered entries to `manifest.json`, merging with any existing content.
    func flush() {
        guard !buffer.isEmpty else { return }
        let toWrite = buffer
        buffer.removeAll(keepingCapacity: true)

        do {
            var existing: [LogEntry] = []
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                let data = try Data(contentsOf: manifestURL)
                existing = (try? JSONDecoder().decode([LogEntry].self, from: data)) ?? []
            }
            let merged = existing + toWrite
            let encoded = try JSONEncoder().encode(merged)
            try encoded.write(to: manifestURL, options: .atomic)
            vlog.debug("VelocityLogger: flushed \(toWrite.count) entries (\(merged.count) total)")
        } catch {
            vlog.error("VelocityLogger flush failed: \(error.localizedDescription)")
            // Put entries back so they're not lost
            buffer = toWrite + buffer
        }
    }
}
