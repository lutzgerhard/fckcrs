// FCKCRS
// Rolling 5-second video clip recorder.
//
// Writes 1-second H.264 segments to the temp directory, keeps the last 6,
// and splices the most recent 5 into a single MP4 on saveClip().
//
// Thread model
// ─────────────
// callbackQueue  — serial; used as AVCaptureVideoDataOutputSampleBufferDelegate
//                  queue AND for all internal state mutations.
// global utility — used for the slow AVAssetExportSession so callbackQueue
//                  is unblocked immediately after finalising the in-flight segment.

@preconcurrency import AVFoundation
import Foundation

final class RollingClipRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    // MARK: - Public

    /// Pass this to AVCaptureVideoDataOutput.setSampleBufferDelegate(_:queue:).
    let callbackQueue = DispatchQueue(label: "com.fckcrs.rollingRecorder", qos: .userInitiated)

    // MARK: - Config

    private let maxSegments       = 6    // history ≈ 6 s
    private let targetSegmentSecs = 1.0  // rotate every second

    // MARK: - State (ALL accessed on callbackQueue only)

    private var isRecording        = true   // paused while gallery is visible
    private var completedSegments: [URL] = []
    private var writer:            AVAssetWriter?
    private var writerInput:       AVAssetWriterInput?
    private var segmentStartPTS:   CMTime = .invalid
    private var currentURL:        URL?

    // MARK: - Pause / resume

    func pause()  { callbackQueue.async { self.isRecording = false } }
    func resume() { callbackQueue.async { self.isRecording = true  } }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        // Called on callbackQueue by AVCaptureSession
        processBuffer(sampleBuffer)
    }

    // MARK: - Save

    /// Finalises the in-flight segment, then splices the last ≤5 completed
    /// segments into one MP4 at `destination`.  `completion` is called on an
    /// arbitrary background thread.
    func saveClip(to destination: URL, completion: @escaping (Bool) -> Void) {
        callbackQueue.async { [self] in
            if writer != nil { finaliseCurrentSegment() }

            // Snapshot URLs — safe to hand off; no instance state needed after this.
            let segs = Array(completedSegments.suffix(5))

            // Do the slow export in a Swift Task so callbackQueue is unblocked
            // and recording resumes immediately for the next segment.
            Task {
                guard !segs.isEmpty else { completion(false); return }
                let ok = await Self.exportClip(from: segs, to: destination)
                completion(ok)
            }
        }
    }

    // MARK: - Private – frame processing

    private func processBuffer(_ buffer: CMSampleBuffer) {
        guard isRecording else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)

        if writer == nil {
            startNewSegment(at: pts)
        } else if segmentStartPTS.isValid {
            let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, segmentStartPTS))
            if elapsed >= targetSegmentSecs { rotateSegment(at: pts) }
        }

        guard let input = writerInput,
              writer?.status == .writing,
              input.isReadyForMoreMediaData else { return }
        input.append(buffer)
    }

    private func startNewSegment(at pts: CMTime) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fckcrs_\(UUID().uuidString).mov")

        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1280,
            AVVideoHeightKey: 720,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey:      2_000_000,
                AVVideoProfileLevelKey:        AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 30
            ] as [String: Any]
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        // No transform here — rotation is baked in at export time via
        // AVMutableVideoComposition so the final MP4 has actual portrait pixels.

        guard w.canAdd(input) else { return }
        w.add(input)
        w.startWriting()
        w.startSession(atSourceTime: pts)

        writer          = w
        writerInput     = input
        segmentStartPTS = pts
        currentURL      = url
    }

    private func rotateSegment(at nextPTS: CMTime) {
        finaliseCurrentSegment()
        startNewSegment(at: nextPTS)
    }

    private func finaliseCurrentSegment() {
        guard let w = writer, let url = currentURL else { return }

        writerInput?.markAsFinished()
        let sema = DispatchSemaphore(value: 0)
        w.finishWriting { sema.signal() }
        sema.wait()

        writer          = nil
        writerInput     = nil
        currentURL      = nil
        segmentStartPTS = .invalid

        guard w.status == .completed else { return }

        completedSegments.append(url)
        while completedSegments.count > maxSegments {
            let old = completedSegments.removeFirst()
            try? FileManager.default.removeItem(at: old)
        }
    }

    // MARK: - Private – export (static async; no instance state needed)

    private static func exportClip(from segments: [URL], to destination: URL) async -> Bool {
        let composition = AVMutableComposition()
        guard let vTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return false }

        var insertAt = CMTime.zero

        for url in segments {
            let asset = AVURLAsset(url: url,
                                   options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            do {
                let duration = try await asset.load(.duration)
                let tracks   = try await asset.loadTracks(withMediaType: .video)
                if let src = tracks.first {
                    try? vTrack.insertTimeRange(
                        CMTimeRangeMake(start: .zero, duration: duration),
                        of: src, at: insertAt
                    )
                    insertAt = CMTimeAdd(insertAt, duration)
                }
            } catch { continue }
        }

        guard insertAt.seconds > 0 else { return false }

        // ── Rotate landscape (1280×720) → portrait (720×1280) ──────────────
        // The sensor delivers landscape frames; we bake a 90° CW rotation into
        // the final MP4 so no player needs to interpret metadata transforms.
        //
        // Transform derivation (AVFoundation y-up coords):
        //   rotate π/2 CCW  →  (0,1,-1,0,0,0)
        //   translate (720,0) to shift back into the [0,720]×[0,1280] canvas
        //   combined: (a:0, b:1, c:-1, d:0, tx:720, ty:0)
        let rotationTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 720, ty: 0)

        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.renderSize    = CGSize(width: 720, height: 1280)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRangeMake(start: .zero, duration: insertAt)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
        layerInstruction.setTransform(rotationTransform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions  = [instruction]

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else { return false }

        exporter.outputURL        = destination
        exporter.outputFileType   = .mp4
        exporter.videoComposition = videoComposition

        // Bridge the completion-handler API to async/await.
        await withCheckedContinuation { cont in
            exporter.exportAsynchronously { cont.resume() }
        }

        return exporter.status == .completed
    }
}
