# Feature: LiDAR Tracking & Velocity Estimation

## Status: Dormant (superseded by vision-based pipeline — see spec 04)

## Overview
**LiDAR is currently dormant.** `LiDARService` is instantiated and started but its
output is not used for distance or speed estimation. Distance and speed are provided
entirely by the vision-based `CarDistanceTracker` (geometric + Kalman filter).

The LiDAR infrastructure is kept in place so it can be re-enabled or layered on top
of the vision pipeline in the future.

---

### Original Spec (for future reference)
On LiDAR-capable devices, use ARKit depth data and camera pose to build a 3D track
of each detected vehicle and estimate its velocity and heading.

## Behaviour
- The app checks at startup whether the device has a LiDAR scanner
  (`ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)`)
- If LiDAR is available:
  - A "LiDAR" badge appears in the top-left of the camera view
  - Speed and heading are shown in the overlay for each tracked vehicle
  - Speed format: `~XX km/h` (or mph per locale)
  - Heading is shown as a compass direction: N, NE, E, SE, S, SW, W, NW
- If LiDAR is not available, these fields are empty/hidden and the rest of the
  app functions normally
- Velocity is estimated by computing the displacement of the vehicle's centroid
  in world space between consecutive ARFrames and dividing by the frame interval
- Speed is smoothed with an exponential moving average (alpha = 0.3) to reduce jitter
- Minimum trackable speed: 1 km/h (below this, speed shows as "stationary")
- Maximum reasonable speed: 300 km/h (above this, discard as noise)

## Technical Notes
- Use `ARWorldTrackingConfiguration` with `.frameSemantics = [.sceneDepth]`
- Each `ARFrame` provides `sceneDepth.depthMap` (CVPixelBuffer) and
  `capturedDepthData` (ARDepthData)
- For each vehicle bounding box, sample the depth map at the centroid pixel
  to get distance in metres
- Convert pixel + depth → 3D world point using ARCamera intrinsics:
  ```
  worldPoint = camera.unprojectPoint(pixelPoint, ontoPlane: ..., orientation: ...)
  ```
  Or use `ARFrame.camera.projectPoint` inverse via intrinsic matrix
- Track world positions over a rolling 10-frame window; fit a linear velocity
  via least-squares or simple first-difference average
- Heading: derive from velocity vector projected onto the horizontal plane
- Store the ARFrame camera transform at the time of each detection record save

## Open Questions
- Should we use mesh reconstruction for occlusion handling? (future, expensive)
- Per-wheel speed from point cloud? (future)
