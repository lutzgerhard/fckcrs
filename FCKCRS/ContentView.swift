// FCKCRS
// Spec: Specs/features/01-main-layout.md

import SwiftUI

struct ContentView: View {

    @EnvironmentObject private var viewModel: ContentViewModel
    /// X offset of the HUD overlay (0 = visible, geo.size.width = off-screen right).
    @State private var hudOffset: CGFloat = 0
    @State private var hudHidden = false
    /// Whether the video gallery is slid into view from the top.
    @State private var galleryVisible = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black

                // Fixed layout: camera top 2/3, map bottom 1/3.
                VStack(spacing: 0) {
                    CameraView()
                        .frame(height: geo.size.height * 2 / 3)
                        .clipped()
                    MapView()
                        .frame(height: geo.size.height * 1 / 3)
                }

                // ── HUD overlay — slides right to hide ───────────────────
                ZStack(alignment: .bottomTrailing) {
                    Color.clear

                    // Status pill – top centre
                    VStack {
                        StatusPill(vehicleCount: viewModel.cameraViewModel.trackedVehicleCount)
                            .padding(.top, geo.safeAreaInsets.top + 8)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .center)

                    // LiDAR badge – top left
                    if viewModel.cameraViewModel.isLiDARActive {
                        VStack {
                            LiDARBadge()
                                .padding(.top, geo.safeAreaInsets.top + 12)
                                .padding(.leading, 12)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Debug HUD – top right
                    VStack {
                        DebugHUDPanel(
                            detectorName: viewModel.cameraViewModel.detectorName,
                            detections: viewModel.cameraViewModel.debugDetections,
                            inferenceSeconds: viewModel.cameraViewModel.lastInferenceSeconds
                        )
                        .padding(.top, max(geo.safeAreaInsets.top, 54) + 16)
                        .padding(.trailing, 12)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)

                }
                .frame(height: geo.size.height * 2 / 3)
                .offset(x: hudOffset)
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onChanged { v in
                            guard !hudHidden else { return }
                            hudOffset = max(0, v.translation.width)
                        }
                        .onEnded { v in
                            guard !hudHidden else { return }
                            // Always resolve to exactly 0 or geo.size.width — never intermediate.
                            let hide = v.translation.width > 80 ||
                                       v.predictedEndTranslation.width > 150
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                hudOffset = hide ? geo.size.width : 0
                                hudHidden = hide
                            }
                        }
                )

                // ── Swipe-left-from-right-edge to restore ─────────────────
                if hudHidden {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: 44, height: geo.size.height * 2 / 3)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .gesture(
                            DragGesture(minimumDistance: 20)
                                .onEnded { v in
                                    guard v.translation.width < -30 else { return }
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                        hudOffset = 0
                                        hudHidden = false
                                    }
                                }
                        )
                }

                // ── Gallery overlay (full-screen, slides down from top) ────
                // offset(y:0) when visible → covers entire screen.
                // allowsHitTesting(galleryVisible) keeps the hidden panel from
                // absorbing touches while it lives off-screen above.
                let galleryH = geo.size.height
                VideoGalleryView(
                    library: viewModel.videoLibrary,
                    topSafeArea: geo.safeAreaInsets.top,
                    bottomSafeArea: geo.safeAreaInsets.bottom
                ) {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) {
                        galleryVisible = false
                    }
                }
                .frame(height: galleryH)
                .frame(maxWidth: .infinity)
                .offset(y: galleryVisible ? 0 : -(galleryH + 4))
                .animation(.spring(response: 0.42, dampingFraction: 0.86), value: galleryVisible)
                .allowsHitTesting(galleryVisible)

                // ── Gallery pull-down handle ──────────────────────────────
                // Uses a real layout height (not offset) so hit-testing is
                // correct.  max(…, 50) guards against safeAreaInsets == 0.
                if !galleryVisible {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity)
                        .frame(height: max(geo.safeAreaInsets.top, 50) + 46)
                        .overlay(alignment: .bottom) {
                            Capsule()
                                .fill(.ultraThinMaterial)
                                .frame(width: 64, height: 24)
                                .overlay {
                                    Capsule()
                                        .fill(Color.white)
                                        .frame(width: 40, height: 5)
                                }
                                .shadow(color: .black.opacity(0.55),
                                        radius: 5, x: 0, y: 2)
                                .padding(.bottom, 10)
                        }
                        .gesture(
                            DragGesture(minimumDistance: 15)
                                .onEnded { v in
                                    guard v.translation.height > 40 else { return }
                                    withAnimation(.spring(response: 0.42,
                                                          dampingFraction: 0.86)) {
                                        galleryVisible = true
                                    }
                                }
                        )
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            viewModel.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            viewModel.stop()
        }
        .overlay(alignment: .top) {
            if viewModel.showSaveConfirmation {
                SavedToast()
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.showSaveConfirmation)
        .animation(.easeInOut(duration: 0.2), value: viewModel.cameraViewModel.trackedVehicleCount)
        .onChange(of: galleryVisible) { _, visible in
            // Pause the rolling recorder while the gallery is on screen so we
            // don't buffer footage the user is actively reviewing, and avoid
            // triggering a save when viewing replaces a car-exit event.
            if visible {
                viewModel.cameraViewModel.cameraService.rollingClipRecorder?.pause()
            } else {
                viewModel.cameraViewModel.cameraService.rollingClipRecorder?.resume()
            }
        }
    }
}

// MARK: - Sub-components

private struct StatusPill: View {
    let vehicleCount: Int
    var body: some View {
        Text(vehicleCount == 0 ? "Scanning…" : "\(vehicleCount) vehicle\(vehicleCount == 1 ? "" : "s")")
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(vehicleCount == 0
                ? Color.black.opacity(0.55)
                : Color.green.opacity(0.75))
            .clipShape(Capsule())
    }
}

private struct LiDARBadge: View {
    var body: some View {
        Text("LiDAR")
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundColor(.cyan)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.6))
            .overlay(Capsule().stroke(Color.cyan.opacity(0.8), lineWidth: 1))
            .clipShape(Capsule())
    }
}

private struct SavedToast: View {
    var body: some View {
        Label("Saved", systemImage: "checkmark.circle.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(Color.green.opacity(0.85))
            .clipShape(Capsule())
    }
}


#Preview {
    ContentView()
        .environmentObject(ContentViewModel())
}
