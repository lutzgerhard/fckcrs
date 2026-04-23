// FCKCRS
// Spec: Specs/features/01-main-layout.md, 07-detection-storage.md

import SwiftUI
import Combine
import ARKit
import Photos

@MainActor
final class ContentViewModel: ObservableObject {

    // MARK: - Sub-ViewModels

    let cameraViewModel: CameraViewModel
    let mapViewModel: MapViewModel

    // MARK: - Published

    @Published var showSaveConfirmation: Bool = false
    @Published var showPhotoToast: Bool = false

    // MARK: - Services (owned here, shared down)

    private let locationService: LocationService
    private let lidarService: LiDARService
    private let plateService: LicensePlateService
    private let detectionService: VehicleDetectionService
    private let speedLimitService: SpeedLimitService
    let videoLibrary = VideoLibraryService()

    // MARK: - State

    private var cancellables = Set<AnyCancellable>()
    private var snapshotTimer: Timer?
    private var currentSessionSnapshots: [UUID: [String]] = [:]

    /// Timestamp of the last clip that was saved; used to enforce the 10 s cooldown.
    private var lastClipDate: Date?
    private let clipCooldownSecs: TimeInterval = 10.0

    // MARK: - Init

    init() {
        let location   = LocationService()
        let lidar      = LiDARService()
        let plate      = LicensePlateService()
        let detect     = VehicleDetectionService(plateService: plate)
        let speedLimit = SpeedLimitService(locationService: location)

        self.locationService   = location
        self.lidarService      = lidar
        self.plateService      = plate
        self.detectionService  = detect
        self.speedLimitService = speedLimit

        self.cameraViewModel   = CameraViewModel(detectionService: detect, lidar: lidar)
        self.mapViewModel      = MapViewModel(locationService: location,
                                             speedLimitService: speedLimit)

        // Forward nested view model changes so views observing ContentViewModel
        // re-render when any sub-viewmodel @Published property changes.
        cameraViewModel.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        mapViewModel.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Save a clip whenever the main tracked car leaves the frame.
        // Uses a sliding pair (previous, current) to detect nil transitions.
        cameraViewModel.$mainCar
            .scan((Optional<DetectedVehicle>.none, Optional<DetectedVehicle>.none)) { acc, next in
                (acc.1, next)
            }
            .filter { prev, curr in prev != nil && curr == nil }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.triggerClipSave() }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func start() {
        Task {
            await cameraViewModel.start(plateService: plateService)
        }
        locationService.requestPermissionAndStart()
        lidarService.start()
        startSnapshotTimer()
    }

    func stop() {
        cameraViewModel.stop()
        locationService.stop()
        lidarService.stop()
        snapshotTimer?.invalidate()
        snapshotTimer = nil
    }

    // MARK: - Manual save

    func saveCurrentDetection() {
        guard let primary = detectionService.detectedVehicles.first(where: { $0.isConfirmed })
            ?? detectionService.detectedVehicles.first else { return }

        let snapshots = currentSessionSnapshots[primary.id] ?? []
        let record = DetectionRecord.make(
            from: primary,
            location: locationService.location,
            lidarAvailable: lidarService.isAvailable,
            snapshots: snapshots
        )

        // Grab annotated frame from camera
        guard let annotated = cameraViewModel.currentAnnotatedFrame() else { return }

        Task {
            try? await DetectionStorage.shared.saveRecord(record, annotatedImage: annotated)
            showSaveConfirmationBriefly()
        }
    }

    // MARK: - Periodic snapshot

    private func startSnapshotTimer() {
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.takePeriodicSnapshot()
            }
        }
    }

    private func takePeriodicSnapshot() {
        guard let annotated = cameraViewModel.currentAnnotatedFrame() else { return }

        for vehicle in detectionService.detectedVehicles where vehicle.isConfirmed {
            Task {
                if let filename = await DetectionStorage.shared.saveSnapshot(
                    image: annotated,
                    sessionID: vehicle.id
                ) {
                    currentSessionSnapshots[vehicle.id, default: []].append(filename)
                }
            }
        }
    }

    // MARK: - Rolling clip save

    private func triggerClipSave() {
        let now = Date()
        if let last = lastClipDate, now.timeIntervalSince(last) < clipCooldownSecs { return }
        guard let recorder = cameraViewModel.cameraService.rollingClipRecorder else { return }
        lastClipDate = now
        videoLibrary.saveClip(from: recorder)
    }

    // MARK: - Take picture

    func savePhoto(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            }) { success, _ in
                guard success else { return }
                Task { @MainActor [weak self] in
                    self?.showPhotoToastBriefly()
                }
            }
        }
    }

    private func showPhotoToastBriefly() {
        showPhotoToast = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            showPhotoToast = false
        }
    }

    // MARK: - Helpers

    private func showSaveConfirmationBriefly() {
        showSaveConfirmation = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            showSaveConfirmation = false
        }
    }
}
