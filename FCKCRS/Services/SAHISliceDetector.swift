// FCKCRS

@preconcurrency import AVFoundation
@preconcurrency import Vision
import CoreML
@preconcurrency import ARKit
import CoreGraphics
import os.log

private let log = Logger(subsystem: "com.fckcrs", category: "SAHISliceDetector")

private let vehicleClassNamesSAHI: Set<String> = ["car", "motorcycle", "bus", "truck"]

// COCO class index → name (for Path B fallback)
private let cocoClassLabelsSAHI: [String] = [
    "person","bicycle","car","motorcycle","airplane","bus","train","truck","boat",
    "traffic light","fire hydrant","stop sign","parking meter","bench","bird","cat",
    "dog","horse","sheep","cow","elephant","bear","zebra","giraffe","backpack",
    "umbrella","handbag","tie","suitcase","frisbee","skis","snowboard","sports ball",
    "kite","baseball bat","baseball glove","skateboard","surfboard","tennis racket",
    "bottle","wine glass","cup","fork","knife","spoon","bowl","banana","apple",
    "sandwich","orange","broccoli","carrot","hot dog","pizza","donut","cake","chair",
    "couch","potted plant","bed","dining table","toilet","tv","laptop","mouse",
    "remote","keyboard","cell phone","microwave","oven","toaster","sink",
    "refrigerator","book","clock","vase","scissors","teddy bear","hair drier","toothbrush"
]

private let CONF_THRESHOLD_SAHI: Float = 0.25
private let IOU_MERGE_THRESHOLD: Float = 0.45
/// Box height threshold in normalised coords below which a detection is "far" (>≈15 m).
private let SMALL_BOX_HEIGHT: CGFloat = 0.12

// MARK: - SAHISliceDetector

/// Multi-scale YOLO detector that runs a full-frame pass plus a horizon-band slice pass,
/// then merges the two result sets with NMS, giving better recall on distant vehicles.
final class SAHISliceDetector: VehicleDetector, @unchecked Sendable {

    let name = "yolo11n-sahi"

    private let vnModel: VNCoreMLModel

    // MARK: - Init

    init() throws {
        guard let modelURL = Bundle.main.url(forResource: "yolo11n", withExtension: "mlmodelc")
                          ?? Bundle.main.url(forResource: "yolo11n", withExtension: "mlpackage") else {
            throw YOLOError.modelNotFound
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
        self.vnModel = try VNCoreMLModel(for: mlModel)
        log.info("SAHISliceDetector: loaded \(modelURL.lastPathComponent)")
    }

    // MARK: - VehicleDetector

    func detect(in buffer: CMSampleBuffer, arFrame: ARFrame?) async -> [RawDetection] {
        let wrapped = _SendableSampleBuffer(buffer: buffer)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [vnModel] in
                // ── Build two requests ────────────────────────────────────────
                let globalReq = VNCoreMLRequest(model: vnModel)
                globalReq.imageCropAndScaleOption = .scaleFill
                // Full frame: default ROI = whole image (CGRect(x:0,y:0,width:1,height:1))

                let sliceReq = VNCoreMLRequest(model: vnModel)
                sliceReq.imageCropAndScaleOption = .scaleFill
                // Vision uses bottom-left origin.
                // We want the horizon band: top-middle of the portrait image.
                // In Vision coords (bottom-left origin):
                //   y=0.2 to y=0.55 from bottom = upper-middle region in portrait.
                sliceReq.regionOfInterest = CGRect(x: 0, y: 0.2, width: 1.0, height: 0.35)

                // ── One handler, two requests ────────────────────────────────
                let handler = VNImageRequestHandler(cmSampleBuffer: wrapped.buffer,
                                                   orientation: .right,
                                                   options: [:])
                do {
                    try handler.perform([globalReq, sliceReq])
                } catch {
                    log.error("SAHISliceDetector perform failed: \(error.localizedDescription)")
                    continuation.resume(returning: [])
                    return
                }

                // ── Parse global results ─────────────────────────────────────
                let globalDets = SAHISliceDetector.parseResults(globalReq, isSlice: false)

                // ── Parse slice results and remap to full-frame coords ────────
                let sliceDetsRaw = SAHISliceDetector.parseResults(sliceReq, isSlice: true)
                let sliceDets = sliceDetsRaw.map { det -> RawDetection in
                    // Remap: by_full = 0.2 + by_roi * 0.35, bh_full = bh_roi * 0.35
                    // bx, bw unchanged.
                    let b = det.boundingBox
                    let remapped = CGRect(
                        x: b.minX,
                        y: 0.2 + b.minY * 0.35,
                        width: b.width,
                        height: b.height * 0.35
                    )
                    return RawDetection(
                        boundingBox: remapped,
                        confidence: det.confidence,
                        classLabel: det.classLabel,
                        method: det.method,
                        isVehicle: det.isVehicle,
                        distanceMetres: det.distanceMetres,
                        speedKmh: det.speedKmh,
                        isApproaching: det.isApproaching
                    )
                }

                // ── NMS merge ────────────────────────────────────────────────
                let merged = SAHISliceDetector.nmsmerge(global: globalDets, slice: sliceDets)
                continuation.resume(returning: merged)
            }
        }
    }

    // MARK: - Warmup

    /// Pre-heats the ANE/CoreML pipeline with 3 dummy inferences.
    func warmUp() {
        Task.detached(priority: .background) { [vnModel] in
            guard let pixelBuffer = SAHISliceDetector.makeBlackPixelBuffer(width: 640, height: 640) else { return }
            for _ in 0..<3 {
                let request = VNCoreMLRequest(model: vnModel)
                request.imageCropAndScaleOption = .scaleFill
                let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
                try? handler.perform([request])
            }
            log.debug("SAHISliceDetector warmup complete")
        }
    }

    // MARK: - Private helpers

    private static func parseResults(_ request: VNCoreMLRequest, isSlice: Bool) -> [RawDetection] {
        // ── Path A: VNRecognizedObjectObservation ────────────────────────────
        if let obs = request.results as? [VNRecognizedObjectObservation] {
            return obs.compactMap { o -> RawDetection? in
                guard let top = o.labels.first, top.confidence >= CONF_THRESHOLD_SAHI else { return nil }
                let b = o.boundingBox  // Vision: bottom-left origin
                // Flip Y to top-left origin
                let flipped = CGRect(x: b.minX, y: 1.0 - b.maxY,
                                     width: b.width, height: b.height)
                return RawDetection(
                    boundingBox: flipped,
                    confidence: top.confidence,
                    classLabel: top.identifier,
                    method: .coreml,
                    isVehicle: vehicleClassNamesSAHI.contains(top.identifier)
                )
            }
        }

        // ── Path B: VNCoreMLFeatureValueObservation ──────────────────────────
        guard let featureObs = request.results as? [VNCoreMLFeatureValueObservation] else {
            return []
        }

        var confArr: MLMultiArray?
        var coordArr: MLMultiArray?
        for obs in featureObs {
            switch obs.featureName {
            case "confidence":  confArr = obs.featureValue.multiArrayValue
            case "coordinates": coordArr = obs.featureValue.multiArrayValue
            default: break
            }
        }

        guard let conf = confArr, let coord = coordArr,
              conf.dataType == .float32, coord.dataType == .float32,
              conf.shape.count == 2, coord.shape.count == 2 else {
            return []
        }

        let numDet = conf.shape[0].intValue
        let numCls = conf.shape[1].intValue
        let confPtr  = conf.dataPointer.assumingMemoryBound(to: Float32.self)
        let coordPtr = coord.dataPointer.assumingMemoryBound(to: Float32.self)

        var dets: [RawDetection] = []
        for d in 0..<numDet {
            var bestClass = -1
            var bestConf: Float = CONF_THRESHOLD_SAHI
            for c in 0..<numCls {
                let score = confPtr[d * numCls + c]
                if score > bestConf { bestConf = score; bestClass = c }
            }
            guard bestClass != -1, bestClass < cocoClassLabelsSAHI.count else { continue }

            let cx = coordPtr[d * 4 + 0]
            let cy = coordPtr[d * 4 + 1]
            let w  = coordPtr[d * 4 + 2]
            let h  = coordPtr[d * 4 + 3]
            let box = CGRect(x: CGFloat(cx - w/2), y: CGFloat(cy - h/2),
                             width: CGFloat(w), height: CGFloat(h))

            let label = cocoClassLabelsSAHI[bestClass]
            dets.append(RawDetection(
                boundingBox: box,
                confidence: bestConf,
                classLabel: label,
                method: .coreml,
                isVehicle: vehicleClassNamesSAHI.contains(label)
            ))
        }
        return dets
    }

    /// Merge global + slice detections with IoU-based NMS.
    private static func nmsmerge(global: [RawDetection], slice: [RawDetection]) -> [RawDetection] {
        var output: [RawDetection] = []
        var suppressedGlobal = Set<Int>()
        var suppressedSlice  = Set<Int>()

        // For each global-slice pair with IoU > threshold, keep one.
        for (gi, gDet) in global.enumerated() {
            for (si, sDet) in slice.enumerated() where !suppressedSlice.contains(si) {
                let iou = gDet.boundingBox.iouFloat(with: sDet.boundingBox)
                guard iou > IOU_MERGE_THRESHOLD else { continue }

                // Decide which to keep
                let keepSlice: Bool
                if gDet.boundingBox.height < SMALL_BOX_HEIGHT {
                    // Small (distant) box — prefer slice detection
                    keepSlice = true
                } else {
                    keepSlice = sDet.confidence >= gDet.confidence
                }

                if keepSlice {
                    suppressedGlobal.insert(gi)
                } else {
                    suppressedSlice.insert(si)
                }
            }
        }

        for (gi, gDet) in global.enumerated() where !suppressedGlobal.contains(gi) {
            output.append(gDet)
        }
        for (si, sDet) in slice.enumerated() where !suppressedSlice.contains(si) {
            output.append(sDet)
        }
        return output
    }

    static func makeBlackPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, nil, &pb)
        return pb
    }
}

// MARK: - CGRect IoU helper (local)

private extension CGRect {
    func iouFloat(with other: CGRect) -> Float {
        let intersection = self.intersection(other)
        guard !intersection.isNull else { return 0 }
        let ia = intersection.width * intersection.height
        let ua = self.width * self.height + other.width * other.height - ia
        guard ua > 0 else { return 0 }
        return Float(ia / ua)
    }
}

// MARK: - Sendable wrapper

private struct _SendableSampleBuffer: @unchecked Sendable {
    let buffer: CMSampleBuffer
}
