# Feature: Map View

## Status: Implemented

## Overview
A MapKit map in the bottom third of the screen that shows the user's current
GPS position as a point-of-interest annotation, plus an accuracy circle.

## Behaviour
- Shows a standard map (not satellite) by default
- The user's location is shown as a custom red pin annotation (not the default blue dot)
- An accuracy circle is drawn around the pin, sized to match GPS accuracy radius
- The map re-centres on the user every time they move more than 10 metres
- Compass and scale bar are visible
- User cannot rotate or tilt the map (rotateEnabled = false, pitchEnabled = false)
- Zoom level is fixed to ~200 m radius (approximately city-block scale) on first load,
  then the user can pinch to zoom freely
- If location permission is denied, the map shows a centred "Location access required"
  overlay with a button that opens iOS Settings

## Technical Notes
- Use `MKMapView` via `UIViewRepresentable` (or SwiftUI Map if it supports all the above)
- `MapViewModel` vends a `CLLocationCoordinate2D` that the view observes
- Accuracy circle: `MKCircle` overlay on the map
- Permission prompt: handled by `LocationService`; if denied, publish `.denied` state

## Open Questions
- Should detected vehicles' last-known locations also be pinned on the map? (future spec)
