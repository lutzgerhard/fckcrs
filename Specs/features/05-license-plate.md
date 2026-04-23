# Feature: License Plate Recognition

## Status: Scaffold

## Overview
For each tracked vehicle, attempt to read the license plate text using
on-device OCR and display it in the camera overlay.

## Behaviour
- Plate recognition runs on the bounding-box crop of each tracked vehicle
- Recognised text is shown in the overlay (see spec 02-camera-view)
- If no plate is found after 3 attempts, the overlay shows "PLATE?"
- Plate text is updated continuously while the vehicle is tracked; if a later
  frame gives higher confidence, the text is updated
- Plate recognition result includes:
  - Text (string)
  - Confidence (0…1)
  - Region (bounding box within vehicle crop, normalised)
- Plate text is stored in `DetectionRecord` when a detection is saved

## Technical Notes
- Use `VNRecognizeTextRequest` (Vision framework)
  - `.recognitionLevel = .accurate`
  - `.usesLanguageCorrection = false` (plates are not natural language)
  - Custom `customWords` hint list with common plate formats (to be added)
- Crop the vehicle bounding box from the current `CMSampleBuffer` before running
  text recognition, to reduce noise from background text (street signs etc.)
- Filter results to strings matching plate regex patterns:
  - US: `[A-Z0-9]{5,8}` (generic initial filter)
  - EU: can be added via spec update later
- If multiple text regions found in crop, score by character count + confidence
  and take the best

## Open Questions
- Should we support a cloud fallback (e.g. OpenALPR / platerecognizer.com)? (not yet)
- State/country plate format filtering? (future spec)
