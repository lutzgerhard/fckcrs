# FCKCRS — Spec-Driven Development Guide

## What is Spec-Driven Development?

In this project, **you write specs, not code**. Claude reads the specs and implements them.

### Workflow

1. **Edit a spec file** in `Specs/features/` to describe what you want
2. **Tell Claude**: "Implement the spec for `<feature>`" or "Update `<feature>` based on the spec"
3. Claude reads the spec, understands the intent, and writes/updates the corresponding code
4. Claude marks which spec version the code implements (via a comment at the top of each file)

### Spec Format

Each spec file is a markdown document with these sections:

```markdown
# Feature Name

## Status
Draft | Ready | Implemented | Needs Revision

## Overview
One paragraph describing what this does and why.

## Behaviour
- Bullet points describing observable user-facing behaviour

## Technical Notes
- Implementation hints, frameworks to use, constraints

## Open Questions
- Anything unresolved
```

### Key Rule

**Do not edit Swift files directly.** Edit specs and ask Claude to implement them.
If you want to tweak something small (a colour, a label), you can describe it in the spec's
`## Behaviour` section and Claude will apply it.

---

## Project Layout

```
FCKCRS/
├── Specs/                    ← You work here
│   ├── README.md             ← This file
│   ├── architecture.md       ← Overall system design
│   └── features/             ← One file per feature area
│       ├── 01-main-layout.md
│       ├── 02-camera-view.md
│       ├── 03-map-view.md
│       ├── 04-car-detection.md
│       ├── 05-license-plate.md
│       ├── 06-lidar-tracking.md
│       ├── 07-detection-storage.md
│       └── 08-detection-review.md
│
├── FCKCRS/                   ← Generated source code (do not edit manually)
│   ├── FCKCRSApp.swift
│   ├── ContentView.swift
│   ├── Views/
│   ├── ViewModels/
│   ├── Models/
│   ├── Services/
│   └── Utilities/
│
└── FCKCRS.xcodeproj/         ← Xcode project
```

---

## Current Feature Status

| Spec | Status | Code File(s) |
|------|--------|-------------|
| Main Layout | Implemented | ContentView.swift |
| Camera View | Implemented | Views/CameraView.swift |
| Map View | Implemented | Views/MapView.swift |
| Car Detection | Implemented | Services/YOLOv8Detector.swift, Services/VehicleDetectionService.swift |
| License Plate | Scaffold | Services/LicensePlateService.swift |
| LiDAR Tracking | Scaffold | Services/LiDARService.swift |
| Detection Storage | Scaffold | Utilities/DetectionStorage.swift |
| Detection Review | Not Started | — |
