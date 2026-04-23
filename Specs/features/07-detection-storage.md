# Feature: Detection Storage

## Status: Scaffold

## Overview
Persist vehicle detection events locally on device — both as periodic automatic
snapshots and as manually triggered saves.

## Behaviour

### Automatic Snapshots
- While any vehicle is being tracked, save one JPEG frame every 2 seconds
- Frame is annotated (bounding boxes + labels burned in) before saving
- Saved to: `Documents/Detections/<trackingID>/<ISO8601-timestamp>.jpg`
- Max 50 snapshots per tracking session (oldest pruned automatically)

### Manual Save
- User taps "Save Detection" button (see spec 01-main-layout)
- Saves the current annotated frame immediately (outside the 2-second cadence)
- Saves a `detection.json` alongside the image with full metadata:
  ```json
  {
    "id": "<uuid>",
    "savedAt": "<ISO8601>",
    "location": { "lat": 0.0, "lon": 0.0, "accuracy": 5.0 },
    "heading": "NE",
    "speedKmh": 42.3,
    "make": "TOYOTA",
    "model": "CAMRY",
    "licensePlate": "ABC1234",
    "plateConfidence": 0.91,
    "detectionMethod": "coreml",
    "lidarAvailable": true,
    "deviceModel": "iPhone 15 Pro",
    "snapshots": ["<timestamp1>.jpg", "<timestamp2>.jpg"]
  }
  ```
- A success toast ("Saved") appears for 1.5 s after a manual save

### Storage Management
- Total storage cap: 2 GB; oldest sessions pruned when cap is exceeded
- A badge on the (future) Review tab shows count of saved detections

## Technical Notes
- `DetectionStorage` is a singleton actor to serialise file I/O
- Images rendered with `UIGraphicsImageRenderer` (draws overlay on top of raw frame)
- JSON encoded/decoded with `Codable` `DetectionRecord` model
- Use `FileManager` with `documentsDirectory` (not cache — must survive reboots)

## Open Questions
- Should we support iCloud backup of detections? (future)
- Video clip instead of still frames? (future spec)
