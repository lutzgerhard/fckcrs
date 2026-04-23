// FCKCRS
// Manages saved video clips: persists to Documents/FCKCRS_Clips/,
// publishes the list, generates thumbnails, and triggers saves from the recorder.

import AVFoundation
import SwiftUI

@MainActor
final class VideoLibraryService: ObservableObject {

    // MARK: - Model

    struct SavedClip: Identifiable {
        let id: UUID
        let url: URL
        let date: Date
        var thumbnail: UIImage?
    }

    // MARK: - Published

    @Published private(set) var clips: [SavedClip] = []

    // MARK: - Private

    private let directory: URL

    // MARK: - Init

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docs.appendingPathComponent("FCKCRS_Clips", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        loadFromDisk()
    }

    // MARK: - Trigger save

    /// Asks the recorder to finalise and export; then adds the result to the library.
    func saveClip(from recorder: RollingClipRecorder) {
        let ts   = Int(Date().timeIntervalSince1970)
        let dest = directory.appendingPathComponent("clip_\(ts).mp4")

        recorder.saveClip(to: dest) { [weak self] success in
            guard success else { return }
            Task { @MainActor [weak self] in
                self?.addClip(at: dest)
            }
        }
    }

    // MARK: - Delete

    func delete(_ clip: SavedClip) {
        try? FileManager.default.removeItem(at: clip.url)
        clips.removeAll { $0.id == clip.id }
    }

    func deleteAll() {
        for clip in clips {
            try? FileManager.default.removeItem(at: clip.url)
        }
        clips.removeAll()
    }

    // MARK: - Private helpers

    private func loadFromDisk() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        clips = files
            .filter { $0.pathExtension == "mp4" }
            .compactMap { url in
                let values = try? url.resourceValues(forKeys: [.creationDateKey])
                let date   = values?.creationDate ?? Date()
                return SavedClip(id: UUID(), url: url, date: date)
            }
            .sorted { $0.date > $1.date }

        loadThumbnails(for: clips)
    }

    private func addClip(at url: URL) {
        let values = try? url.resourceValues(forKeys: [.creationDateKey])
        let date   = values?.creationDate ?? Date()
        let clip   = SavedClip(id: UUID(), url: url, date: date)
        clips.insert(clip, at: 0)

        let id = clip.id
        Task { [weak self] in
            if let thumb = await makeThumbnail(url: url) {
                await MainActor.run { [weak self] in
                    guard let i = self?.clips.firstIndex(where: { $0.id == id }) else { return }
                    self?.clips[i].thumbnail = thumb
                }
            }
        }
    }

    private func loadThumbnails(for list: [SavedClip]) {
        Task { [weak self] in
            for clip in list {
                if let thumb = await makeThumbnail(url: clip.url) {
                    let id = clip.id
                    await MainActor.run { [weak self] in
                        guard let i = self?.clips.firstIndex(where: { $0.id == id }) else { return }
                        self?.clips[i].thumbnail = thumb
                    }
                }
            }
        }
    }
}

// MARK: - Thumbnail helper (free function; uses Swift Concurrency)

private func makeThumbnail(url: URL) async -> UIImage? {
    let asset = AVURLAsset(url: url)
    let gen   = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 320, height: 180)

    do {
        // iOS 16+ async API
        let (cgImage, _) = try await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600))
        return UIImage(cgImage: cgImage)
    } catch {
        return nil
    }
}
