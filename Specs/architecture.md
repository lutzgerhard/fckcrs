# FCKCRS — Architecture

## Status: Reference

## Overview

FCKCRS is an iOS app that uses the device camera and GPS to detect, track, and record
vehicles in view. It overlays detection results in real-time on the camera feed, and
persists detection records locally for later review or upload.

---

## Layer Diagram

```
┌─────────────────────────────────────────────────────┐
│                     UI Layer                        │
│  ContentView                                        │
│  ├── CameraView (top 2/3)                           │
│  │   ├── CameraPreviewView (AVCaptureVideoPreviewLayer) │
│  │   └── DetectionOverlayView (bounding box + HUD)  │
│  └── MapView (bottom 1/3)                           │
│      └── GPS POI marker                             │
└──────────────┬──────────────────────────────────────┘
               │ @Published state
┌──────────────▼──────────────────────────────────────┐
│                  ViewModel Layer                    │
│  ContentViewModel  (root coordinator)               │
│  CameraViewModel   (detection state + camera ctrl)  │
│  MapViewModel      (location state)                 │
└──────────────┬──────────────────────────────────────┘
               │ async/await calls
┌──────────────▼──────────────────────────────────────┐
│                  Service Layer                      │
│  CameraService          — AVFoundation session      │
│  LiDARService           — ARKit (dormant)           │
│  VehicleDetectionService — Vision + CoreML pipeline │
│  CarDistanceTracker     — geometric + Kalman filter │
│  LicensePlateService    — Vision text recognition   │
│  LocationService        — CoreLocation GPS          │
└──────────────┬──────────────────────────────────────┘
               │ models
┌──────────────▼──────────────────────────────────────┐
│                   Model Layer                       │
│  RawDetection      — bbox, class, confidence,       │
│                      distanceMetres, speedKmh       │
│  DetectedVehicle   — tracked vehicle with UUID      │
│  LicensePlate      — text, confidence, region       │
│  DetectionRecord   — full snapshot: image + meta    │
└──────────────┬──────────────────────────────────────┘
               │ file I/O
┌──────────────▼──────────────────────────────────────┐
│                  Storage Layer                      │
│  DetectionStorage  — local image + JSON persistence │
│  (future) AWSUploader — S3 / DynamoDB upload        │
└─────────────────────────────────────────────────────┘
```

---

## Key Design Decisions

### Detection Pipeline
`VehicleDetectionService` runs `YOLOv8Detector` at up to 5 Hz on 640×640 BGRA buffers
delivered by the ISP. Detection uses `VNCoreMLRequest` with a YOLOv8n NMS pipeline
model (`yolov8n.mlpackage`); Vision maps outputs to `VNRecognizedObjectObservation`.
Compute units: `.cpuAndNeuralEngine`.

### Distance & Speed (CarDistanceTracker)
All distance and speed data comes from `CarDistanceTracker` — a pure vision-based
approach with no LiDAR dependency:
- **Geometric formula**: `d = fy * cameraHeight / (yBottomPx - cy)` using bounding
  box bottom edge as the ground contact point and camera intrinsics from
  `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`
- **Kalman filter**: 2-state `[distance, velocity]` per tracked vehicle;
  constant-velocity process model; covariance propagated as `(pdd, pdv, pvv)`
- LiDAR (`LiDARService`) is instantiated and kept dormant for future use

### Detection Prioritisation
`topDetection` (the single detection shown in the main overlay) prefers:
1. Car / truck / bus
2. Motorcycle / bicycle
3. Other classes
Highest confidence breaks ties within each tier.

### Screenshot Capture
`AVCaptureVideoPreviewLayer` is GPU-rendered and invisible to `UIView.drawHierarchy`.
Workaround: on capture, `CameraView` receives a `freezeFrame: UIImage?`; SwiftUI
renders it as a `UIImageView`-backed `Image` over the preview layer; `drawHierarchy`
then captures the full window including the still frame and all overlays.

### Image Capture Cadence
While a vehicle is in frame, one annotated JPEG is saved to disk every 2 seconds.
The "Save Detection" button saves a snapshot + `detection.json` immediately.
The camera icon button saves a full-app screenshot to the Photos library.

### Concurrency Model
- All services publish to `@MainActor` via `@Published` properties
- Heavy inference runs on a background queue (`DispatchQueue.global(qos: .userInitiated)`)
- Camera frames delivered via `AVCaptureVideoDataOutputSampleBufferDelegate` on a
  dedicated capture queue; `CMSampleBuffer` forwarded to `VehicleDetectionService`

### Persistence Format
```
Documents/Detections/
  <uuid>/
    snapshot_<timestamp>.jpg   ← captured every 2 s while tracked
    detection.json             ← metadata (see DetectionRecord model)
```

### Future AWS Integration
- Images → S3 bucket
- Metadata → DynamoDB or API Gateway → Lambda
- Auth → Cognito
All upload logic will live in a separate `AWSUploader` service.

---

## Frameworks

| Framework    | Purpose                                      |
|--------------|----------------------------------------------|
| SwiftUI      | All UI                                       |
| AVFoundation | Camera capture session                       |
| ARKit        | LiDAR (dormant)                              |
| Vision       | VNCoreMLRequest, text recognition            |
| CoreML       | YOLOv8n NMS inference                        |
| MapKit       | Map + annotation display                     |
| CoreLocation | GPS coordinates                              |
| Combine / async-await | Reactive data flow                  |
