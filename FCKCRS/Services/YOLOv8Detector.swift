// FCKCRS
// Spec: Specs/features/04-car-detection.md
// Implements VehicleDetector using YOLOv8n (COCO-trained) via CoreML + Vision.
//
// The bundled model is a CoreML pipeline (Ultralytics export):
//   Stage 0: mlProgram — YOLOv8n backbone → raw predictions
//   Stage 1: nonMaximumSuppression — produces 'confidence' [N,80] and 'coordinates' [N,4]
//
// Vision may map the outputs to VNRecognizedObjectObservation (auto path),
// or return VNCoreMLFeatureValueObservation (manual parse path). Both are handled.

@preconcurrency import AVFoundation
@preconcurrency import Vision
import CoreML
@preconcurrency import ARKit
import CoreGraphics
import os.log

private let log = Logger(subsystem: "com.fckcrs", category: "YOLOv8")

private struct SendableSampleBuffer: @unchecked Sendable {
    let buffer: CMSampleBuffer
}

private let vehicleClassNames: Set<String> = ["car", "motorcycle", "bus", "truck"]

// COCO class index → name (for the manual-parse fallback path)
private let cocoClassLabels: [String] = [
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

private let CONF_THRESHOLD: Float = 0.25

// MARK: - YOLOv8CoreMLDetector

final class YOLOv8CoreMLDetector: VehicleDetector, @unchecked Sendable {

    let name = "yolo11n-coreml"

    private let vnModel: VNCoreMLModel

    // MARK: - Init

    init() throws {
        // Xcode may compile .mlpackage → .mlmodelc, or leave it as .mlpackage.
        guard let modelURL = Bundle.main.url(forResource: "yolo11n", withExtension: "mlmodelc")
                          ?? Bundle.main.url(forResource: "yolo11n", withExtension: "mlpackage") else {
            throw YOLOError.modelNotFound
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let mlModel = try MLModel(contentsOf: modelURL, configuration: config)
        self.vnModel = try VNCoreMLModel(for: mlModel)
        log.info("YOLO11n pipeline loaded from \(modelURL.lastPathComponent) — ANE+CPU")
    }

    // MARK: - VehicleDetector

    func detect(in buffer: CMSampleBuffer, arFrame: ARFrame?) async -> [RawDetection] {
        let wrapped = SendableSampleBuffer(buffer: buffer)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [vnModel] in
                let request = VNCoreMLRequest(model: vnModel)
                request.imageCropAndScaleOption = .scaleFill

                let handler = VNImageRequestHandler(cmSampleBuffer: wrapped.buffer,
                                                    orientation: .right,
                                                    options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    log.error("perform failed: \(error.localizedDescription)")
                    continuation.resume(returning: [])
                    return
                }

                // ── Path A: Vision auto-mapped to VNRecognizedObjectObservation ──
                // An empty array is valid (no detections this frame) — don't fall through.
                if let obs = request.results as? [VNRecognizedObjectObservation] {
                    let dets = obs.compactMap { o -> RawDetection? in
                        guard let top = o.labels.first, top.confidence >= CONF_THRESHOLD else { return nil }
                        // Vision uses bottom-left origin — flip Y for our top-left UI
                        let b = o.boundingBox
                        let flipped = CGRect(x: b.minX, y: 1.0 - b.maxY,
                                            width: b.width, height: b.height)
                        return RawDetection(boundingBox: flipped, confidence: top.confidence,
                                           classLabel: top.identifier, method: .coreml,
                                           isVehicle: vehicleClassNames.contains(top.identifier))
                    }
                    continuation.resume(returning: dets)
                    return
                }

                // ── Path B: VNCoreMLFeatureValueObservation — parse manually ──
                guard let featureObs = request.results as? [VNCoreMLFeatureValueObservation] else {
                    log.warning("Unexpected result type: \(String(describing: request.results))")
                    continuation.resume(returning: [])
                    return
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
                    // No detections or unexpected array format — return empty.
                    continuation.resume(returning: [])
                    return
                }

                let numDet = conf.shape[0].intValue
                let numCls = conf.shape[1].intValue
                let confPtr  = conf.dataPointer.assumingMemoryBound(to: Float32.self)
                let coordPtr = coord.dataPointer.assumingMemoryBound(to: Float32.self)

                var dets: [RawDetection] = []
                for d in 0..<numDet {
                    var bestClass = -1
                    var bestConf: Float = CONF_THRESHOLD
                    for c in 0..<numCls {
                        let score = confPtr[d * numCls + c]
                        if score > bestConf { bestConf = score; bestClass = c }
                    }
                    guard bestClass != -1, bestClass < cocoClassLabels.count else { continue }

                    // NMS coordinates: [cx, cy, w, h] normalized [0,1], top-left origin
                    let cx = coordPtr[d * 4 + 0]
                    let cy = coordPtr[d * 4 + 1]
                    let w  = coordPtr[d * 4 + 2]
                    let h  = coordPtr[d * 4 + 3]
                    let box = CGRect(x: CGFloat(cx - w/2), y: CGFloat(cy - h/2),
                                    width: CGFloat(w), height: CGFloat(h))

                    let label = cocoClassLabels[bestClass]
                    dets.append(RawDetection(boundingBox: box, confidence: bestConf,
                                            classLabel: label, method: .coreml,
                                            isVehicle: vehicleClassNames.contains(label)))
                }
                continuation.resume(returning: dets)
            }
        }
    }

    // MARK: - Warmup

    /// Pre-heats the ANE/CoreML pipeline with 3 dummy inferences on a background thread.
    func warmUp() {
        Task.detached(priority: .background) { [vnModel] in
            guard let pixelBuffer = Self.makeBlackPixelBuffer(width: 640, height: 640) else { return }
            for _ in 0..<3 {
                let request = VNCoreMLRequest(model: vnModel)
                request.imageCropAndScaleOption = .scaleFill
                let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
                try? handler.perform([request])
            }
        }
    }

    private static func makeBlackPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                            kCVPixelFormatType_32BGRA, nil, &pb)
        return pb
    }
}

// MARK: - Error

enum YOLOError: Error {
    case modelNotFound
}
