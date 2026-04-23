# Feature: Camera View

## Status: Implemented

## Overview
Live camera feed occupying the top 2/3 of the screen, with a transparent overlay
that renders a bounding box, distance estimate, and velocity estimate for the
highest-priority detected vehicle. A debug HUD panel shows up to 4 detections
with confidence, distance, and speed.

## Behaviour
- Camera feed fills the entire allocated region (aspect fill), rear wide camera
- Frame rate capped at 30 fps (reduces ISP/thermal load)
- 2× optical zoom applied at startup
- Overlay draws a bounding box for the top detection:
  - White stroke with glow, corner radius 4 pt, line width 5 pt
  - A subtle black dim (10% opacity) applied when any detection is present
- Label pill above the bounding box shows: `CLASS CONF% DIST SPEED`
  - e.g. `CAR 91% 14.2m ↓38km/h`
  - Distance: Kalman-filtered geometric estimate (cyan in HUD when from Kalman,
    dim white when pinhole fallback)
  - Speed: shown when ≥ 2 km/h; arrow ↓ = approaching, ↑ = receding
  - Units follow system locale (metric / imperial)
- Debug HUD panel (top-right) shows up to 4 detections sorted by confidence:
  - Red dot = vehicle class, cyan dot = non-vehicle
  - Columns: class label, distance, speed, confidence %
- A small "LiDAR" badge appears in the top-left when LiDAR is active
  (LiDAR is dormant and not used for distance; badge does not appear in practice)

## Distance & Speed Estimation
- Source: `CarDistanceTracker` (geometric + Kalman, vision-based — no LiDAR)
- Method: pinhole ground-plane — bottom edge of bounding box used as ground contact
  - `d = fy * cameraHeight / (yBottomPx - cy)`
  - Camera height assumed 1.35 m (driver eye level)
- Kalman filter: 2-state `[distance, velocity]`, constant-velocity model
  - Initialized on first observation; reports speed after ≥ 2 frames
- Intrinsics: extracted from `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`
  on each sample buffer; portrait-rotated from landscape sensor coordinates
- Priority: car/truck/bus beat motorcycle/bicycle/other for `topDetection`

## Screenshot Capture
- Camera button (bottom-left) saves a full-app screenshot to Photos
- `AVCaptureVideoPreviewLayer` is GPU-rendered and invisible to `drawHierarchy`
- Workaround: on tap, a still UIImage is placed as a SwiftUI `Image` over the
  preview layer; after two main-queue hops (to let SwiftUI render), `drawHierarchy`
  is called; the freeze frame is then cleared

## Technical Notes
- Camera preview: `AVCaptureVideoPreviewLayer` in `PreviewUIView: UIView`
  (`layerClass` override), wrapped in `CameraPreviewView: UIViewRepresentable`
- `CameraView` accepts an optional `freezeFrame: UIImage?` for screenshot capture
- Overlay: SwiftUI `ZStack` with `RoundedRectangle` strokes and `Text` pills
- Bounding box coordinates from `CameraViewModel.topDetection` as normalised
  `CGRect` values (0…1); animated with `.easeInOut(duration: 0.08)` on change
- Camera buffers: 640×640 BGRA (ISP center-crops 1280×720 → 720×720 → 640×640)
- Intrinsic matrix delivery enabled on the `AVCaptureVideoDataOutput` connection

## Open Questions
- Should the overlay be a Metal layer for performance at high vehicle counts? (not yet)
- Torch/flashlight control? (not now)
