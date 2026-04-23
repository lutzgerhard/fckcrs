// FCKCRS
// Gallery overlay — slides down from the top of the screen.
// • Swipe UP on the header pill to dismiss.
// • Tap a thumbnail to play the full clip.

import SwiftUI
import AVKit

struct VideoGalleryView: View {

    @ObservedObject var library: VideoLibraryService
    /// Passed from the outer GeometryReader so the gallery can clear the
    /// Dynamic Island (top) and home-indicator (bottom) safe areas.
    var topSafeArea:    CGFloat = 0
    var bottomSafeArea: CGFloat = 0
    let onDismiss: () -> Void

    @State private var selected: VideoLibraryService.SavedClip?
    /// Tracks live drag offset so the gallery follows your finger.
    @State private var dragOffset: CGFloat = 0
    @State private var showClearConfirmation = false

    var body: some View {
        VStack(spacing: 0) {

            // ── Header — drag target for dismiss ─────────────────────────────
            VStack(spacing: 8) {
                // Clear spacer that pushes content below the Dynamic Island
                Color.clear.frame(height: topSafeArea)

                // Prominent dismiss pill — tap OR drag up to dismiss
                ZStack {
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 64, height: 22)
                    Capsule()
                        .fill(Color.white.opacity(0.90))
                        .frame(width: 40, height: 5)
                }
                .padding(.top, 6)
                .shadow(color: .black.opacity(0.4), radius: 3, x: 0, y: 1)
                // Tap the pill itself to dismiss
                .onTapGesture { onDismiss() }

                HStack(alignment: .firstTextBaseline) {
                    Text("Recorded Clips")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    if !library.clips.isEmpty {
                        Text("\(library.clips.count)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.white.opacity(0.45))

                        Button("Clear") {
                            showClearConfirmation = true
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.red.opacity(0.85))
                        .padding(.leading, 10)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }
            .frame(maxWidth: .infinity)
            .background(Color(white: 0.10))
            // Gesture lives on the header only — doesn't conflict with ScrollView
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onChanged { v in
                        if v.translation.height < 0 {
                            dragOffset = v.translation.height
                        }
                    }
                    .onEnded { v in
                        if v.translation.height < -20 ||
                           v.predictedEndTranslation.height < -50 {
                            dragOffset = 0
                            onDismiss()
                        } else {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                dragOffset = 0
                            }
                        }
                    }
            )

            Divider().background(Color.white.opacity(0.12))

            // ── Content ──────────────────────────────────────────────────────
            if library.clips.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 32))
                        .foregroundColor(.white.opacity(0.25))
                    Text("No clips recorded yet")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.35))
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 6),
                            GridItem(.flexible(), spacing: 6)
                        ],
                        spacing: 6
                    ) {
                        ForEach(library.clips) { clip in
                            ClipCell(clip: clip) {
                                selected = clip
                            } onDelete: {
                                library.delete(clip)
                            }
                        }
                    }
                    .padding(8)
                    // Keep the last row clear of the home-indicator / OS swipe zone
                    .padding(.bottom, max(bottomSafeArea, 20))
                }
            }
        }
        .background(Color(white: 0.06))
        .confirmationDialog("Delete all clips?", isPresented: $showClearConfirmation,
                            titleVisibility: .visible) {
            Button("Delete All", role: .destructive) { library.deleteAll() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This cannot be undone.")
        }
        // ── Whole-gallery upward-swipe dismiss ───────────────────────────────
        // simultaneousGesture lets the ScrollView still scroll normally.
        // We only respond on .onEnded with a clear upward intent.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { v in
                    // Only track clearly upward drags (negative Y, not much horizontal)
                    if v.translation.height < 0 &&
                       abs(v.translation.height) > abs(v.translation.width) * 1.2 {
                        dragOffset = v.translation.height
                    }
                }
                .onEnded { v in
                    let isUpward = v.translation.height < -40 &&
                                   abs(v.translation.height) > abs(v.translation.width) * 1.2
                    let isFlick  = v.predictedEndTranslation.height < -80
                    if isUpward || isFlick {
                        dragOffset = 0
                        onDismiss()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            dragOffset = 0
                        }
                    }
                }
        )
        .offset(y: min(dragOffset, 0))   // gallery moves up with finger, never down
        .fullScreenCover(item: $selected) { clip in
            ClipPlayerView(url: clip.url)
        }
    }
}

// MARK: - Clip thumbnail cell

private struct ClipCell: View {

    let clip: VideoLibraryService.SavedClip
    let onPlay:   () -> Void
    let onDelete: () -> Void

    private var timeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: clip.date)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Thumbnail / placeholder
            Group {
                if let img = clip.thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.07))
                        .overlay(
                            Image(systemName: "video.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.white.opacity(0.18))
                        )
                }
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(9 / 16, contentMode: .fill)   // portrait aspect
            .clipped()

            // Bottom scrim + metadata
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .center, endPoint: .bottom
            )

            HStack(alignment: .bottom, spacing: 4) {
                Text(timeLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.75))
                    .padding(.leading, 6)
                    .padding(.bottom, 5)

                Spacer(minLength: 0)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.65))
                        .padding(6)
                }
            }

            // Play-icon overlay
            Image(systemName: "play.circle.fill")
                .font(.system(size: 30))
                .foregroundColor(.white.opacity(0.70))
                .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .cornerRadius(8)
        .clipped()
        .onTapGesture(perform: onPlay)
    }
}

// MARK: - Full-screen player

private struct ClipPlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    // AVPlayer MUST be stored in @State; creating it inline in body causes
    // immediate release → the video shows one frozen frame and never plays.
    @State private var player: AVPlayer

    init(url: URL) {
        self.url = url
        _player  = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: player)
                .ignoresSafeArea()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white, Color.black.opacity(0.5))
                    .padding(.top, 56)
                    .padding(.trailing, 16)
            }
        }
        .onAppear  { player.play()  }
        .onDisappear { player.pause() }
    }
}
