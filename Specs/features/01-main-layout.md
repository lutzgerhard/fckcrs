# Feature: Main Layout

## Status: Implemented

## Overview
The root screen of the app. Divides the display into two regions:
the camera feed (top 2/3) and the map (bottom 1/3).

## Behaviour
- The screen is always full-screen, no navigation bars
- Top 2/3 of the screen shows the live camera feed with detection overlays
- Bottom 1/3 of the screen shows the map
- A floating "Save Detection" button appears in the bottom-right of the camera region
  when at least one vehicle is currently detected
- A camera icon button sits in the bottom-left of the camera region (always visible)
  - Tapping it saves a full screenshot of the entire app to the Photos library
  - The screenshot includes the live camera frame, detection overlays, HUD, and the map
  - The button hides itself from the screenshot (opacity 0 during capture)
  - A "Photo saved" toast confirms success
- Status indicator (small pill) at the top of the camera region shows:
  - "Scanning…" when no vehicles are detected
  - "N vehicle(s)" when N vehicles are tracked
- The app runs in portrait orientation only (for now)
- Screen always stays on while the app is active (idleTimerDisabled = true)

## Technical Notes
- Use GeometryReader to calculate the 2/3 : 1/3 split dynamically
- ContentView owns the split; CameraView and MapView are children
- The save button calls `ContentViewModel.saveCurrentDetection()`
- The screenshot button calls `ContentViewModel.savePhoto(_:)` with a composited UIImage
- Screenshot capture: freeze the live preview as a SwiftUI `Image`, call `drawHierarchy`,
  then clear the freeze frame — required because `AVCaptureVideoPreviewLayer` is GPU-only
  and renders as opaque black in `drawHierarchy` without this workaround

## Open Questions
- Should landscape be supported in a future spec? (not now)
