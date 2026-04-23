# Feature: Car Detection

## Status: Implemented (YOLOv8n NMS pipeline, vision-based distance/speed)

## Overview
Detect vehicles in the camera frame using a CoreML YOLOv8n model, assign persistent
tracking IDs, estimate distance and speed via a geometric Kalman filter, and publish
results to the overlay system.

## Behaviour
- Detection runs continuously while the camera is active at up to 5 Hz
- Each detected vehicle receives a UUID tracking ID that persists across frames
  as long as the vehicle stays in view (IOU-based tracking, threshold 0.3)
- When a vehicle disappears from frame for > 3 seconds, its tracking ID is retired
- Each detection result (`RawDetection`) contains:
  - Bounding box (normalised 0…1, top-left origin)
  - Confidence score (0…1)
  - Class label (COCO class name)
  - `isVehicle` flag (car, truck, bus, motorcycle, bicycle)
  - `distanceMetres: Double?` — Kalman-filtered geometric estimate
  - `speedKmh: Double?` — Kalman velocity in km/h
  - `isApproaching: Bool` — true when velocity is positive (vehicle getting closer)
- `topDetection` prioritisation:
  1. Car / truck / bus (primary vehicles)
  2. Motorcycle / bicycle
  3. Any other detected class
  4. Highest confidence breaks ties within each group

## Distance & Speed Pipeline (`CarDistanceTracker`)
- Geometric ground-plane formula using camera intrinsics:
  - `d = fy * cameraHeight / (yBottomPx - cy)`
  - `cameraHeight` = 1.35 m (assumed driver eye level)
  - Bottom edge of bounding box used as ground contact point
- Intrinsics extracted per-frame from `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`
  and rotated from landscape sensor space to portrait UI space
- 2-state linear Kalman filter `[distance (m), velocity (m/s)]` per tracked vehicle:
  - Constant-velocity process model `F = [[1,dt],[0,1]]`
  - White-noise-acceleration process noise `Q`
  - Scalar measurement `H = [1, 0]`
  - Covariance tracked as `(pdd, pdv, pvv)`
- LiDAR is **not used** for distance or speed (dormant — see spec 06)

## Technical Notes
- Model: `yolov8n.mlpackage` — Ultralytics export with `nms=True`
  - 2-stage CoreML pipeline: mlProgram (inference) + nonMaximumSuppression
  - Vision maps outputs to `VNRecognizedObjectObservation` (Path A)
  - Path B manually parses `VNCoreMLFeatureValueObservation` as fallback
  - `computeUnits = .cpuAndNeuralEngine` — ANE-first with CPU fallback
  - Input: 640×640 BGRA (delivered by ISP at native size, zero CPU resize)
  - Confidence threshold: 0.25; IOU threshold: 0.7
- `VehicleDetectionService` owns `CarDistanceTracker` and `YOLOv8Detector`
- Camera intrinsics enabled via `connection.isCameraIntrinsicMatrixDeliveryEnabled = true`

## Future / Pluggable Detectors
Add a new type conforming to `VehicleDetector` protocol, register it in
`VehicleDetectionService.makeDetector()` factory:
- YOLO11n (newer architecture, same export process)
- RF-DETR (when a CoreML export becomes available)
- SAM v3 (segment-anything, for precise masks)

## Open Questions
- Upgrade to YOLO11n for higher mAP at same speed? (planned)
- Make/model identification: dedicated CoreML classifier on cropped ROI (future)
- Calibrate `cameraHeight` from user input or EXIF? (future)
