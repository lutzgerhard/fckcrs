// FCKCRS
// Spec: Specs/features/07-detection-storage.md

import UIKit
import CoreGraphics

/// Serialises all file I/O for detection records.
/// Singleton actor to prevent concurrent writes.
actor DetectionStorage {

    static let shared = DetectionStorage()
    private init() {}

    // MARK: - Paths

    private var detectionsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Detections", isDirectory: true)
    }

    private func sessionDir(for id: UUID) -> URL {
        detectionsRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: - Snapshot (automatic, every 2 s)

    /// Save an annotated JPEG frame for the given tracking session.
    /// Returns the filename saved, or nil on failure.
    @discardableResult
    func saveSnapshot(
        image: UIImage,
        sessionID: UUID
    ) async -> String? {
        let dir = sessionDir(for: sessionID)
        try? FileManager.default.createDirectory(at: dir,
                                                  withIntermediateDirectories: true)

        // Prune if over 50 snapshots (spec)
        pruneSnapshotsIfNeeded(in: dir, max: 50)

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "\(timestamp).jpg"
        let url = dir.appendingPathComponent(filename)

        guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    // MARK: - Manual save

    /// Write the full detection record (image + JSON) for a manual save.
    func saveRecord(
        _ record: DetectionRecord,
        annotatedImage: UIImage
    ) async throws {
        let dir = sessionDir(for: record.id)
        try FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)

        // Save annotated image
        let imgFilename = "detection_\(ISO8601DateFormatter().string(from: record.savedAt).replacingOccurrences(of: ":", with: "-")).jpg"
        if let data = annotatedImage.jpegData(compressionQuality: 0.9) {
            try data.write(to: dir.appendingPathComponent(imgFilename), options: .atomic)
        }

        // Save JSON metadata
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(record)
        try jsonData.write(to: dir.appendingPathComponent("detection.json"), options: .atomic)

        // Enforce 2 GB total cap
        enforceStorageCap(root: detectionsRoot, maxBytes: 2 * 1024 * 1024 * 1024)
    }

    // MARK: - Read

    func allRecords() throws -> [DetectionRecord] {
        guard FileManager.default.fileExists(atPath: detectionsRoot.path) else { return [] }
        let dirs = try FileManager.default.contentsOfDirectory(
            at: detectionsRoot,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return dirs.compactMap { dir in
            let jsonURL = dir.appendingPathComponent("detection.json")
            guard let data = try? Data(contentsOf: jsonURL) else { return nil }
            return try? decoder.decode(DetectionRecord.self, from: data)
        }
        .sorted { $0.savedAt > $1.savedAt }
    }

    func snapshotURLs(for record: DetectionRecord) -> [URL] {
        let dir = sessionDir(for: record.id)
        return record.snapshots.map { dir.appendingPathComponent($0) }
    }

    // MARK: - Delete

    func deleteRecord(_ record: DetectionRecord) throws {
        let dir = sessionDir(for: record.id)
        try FileManager.default.removeItem(at: dir)
    }

    // MARK: - Helpers

    private func pruneSnapshotsIfNeeded(in dir: URL, max: Int) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }
        let jpegs = files.filter { $0.pathExtension.lowercased() == "jpg" }
            .sorted { urlDate($0) < urlDate($1) }
        if jpegs.count >= max {
            let toDelete = jpegs.prefix(jpegs.count - max + 1)
            toDelete.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

    private func enforceStorageCap(root: URL, maxBytes: Int64) {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.creationDateKey, .totalFileSizeKey],
            options: .skipsHiddenFiles
        ) else { return }

        var totalSize: Int64 = 0
        let sorted = dirs.sorted { urlDate($0) < urlDate($1) }
        for dir in sorted {
            if let size = (try? dir.resourceValues(forKeys: [.totalFileSizeKey]))?.totalFileSize {
                totalSize += Int64(size)
            }
        }
        for dir in sorted {
            guard totalSize > maxBytes else { break }
            if let size = (try? dir.resourceValues(forKeys: [.totalFileSizeKey]))?.totalFileSize {
                try? FileManager.default.removeItem(at: dir)
                totalSize -= Int64(size)
            }
        }
    }

    private func urlDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }
}
