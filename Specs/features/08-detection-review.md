# Feature: Detection Review

## Status: Not Started

## Overview
A screen that lets the user browse all previously saved detection records, view
the captured images and metadata, and (in a future phase) upload them to AWS.

## Behaviour

### List View
- Accessible via a tab bar item "Review" (list icon)
- Shows a scrollable list of detection records, most recent first
- Each row shows:
  - Thumbnail of first snapshot
  - Date/time
  - Make + model (or "Unknown Vehicle")
  - License plate (or "—")
  - Speed + heading
  - Location (street address via reverse geocoding, or lat/lon if unavailable)
- Swipe-to-delete removes the local record and its images

### Detail View
- Tap a row → detail screen
- Horizontal scroll gallery of all snapshots for that session
- Full metadata card below the gallery
- A map thumbnail showing the detection location
- "Upload to AWS" button (disabled/greyed until AWS is configured)
- "Share" button: exports a ZIP of images + JSON via iOS share sheet

### Upload (Future Phase)
- Requires AWS credentials configured in app Settings (future spec)
- Uploads images to S3, metadata to DynamoDB via API Gateway
- Upload progress shown inline
- Uploaded records are marked with a cloud badge

## Technical Notes
- Read from `DetectionStorage` actor
- Reverse geocoding: `CLGeocoder.reverseGeocodeLocation`
- Upload: stub `AWSUploader` protocol with a `LocalOnlyUploader` no-op default

## Open Questions
- Should records sync across devices via CloudKit? (future)
- Search / filter by date, plate, speed? (future)
