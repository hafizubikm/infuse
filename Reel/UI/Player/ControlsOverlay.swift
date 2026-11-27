import SwiftUI

/// Minimal, auto-hiding player controls: play/pause, seek bar with times, full screen.
struct ControlsOverlay: View {
    let controller: PlaybackController
    let ui: PlayerUIState

    var body: some View {
        ZStack(alignment: .bottom) {
            // Click to play/pause, double-click for full screen.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { ui.toggleFullScreen?() }
                .onTapGesture(count: 1) { controller.togglePlayPause(); ui.onActivity?() }

            statusOverlay

            if ui.showInfo {
                InfoOverlay(controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 40).padding(.leading, 24)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if ui.controlsVisible {
                ControlBar(controller: controller, ui: ui)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder private var statusOverlay: some View {
        if case .failed(let message) = controller.status {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle)
                Text(message).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .frame(maxHeight: .infinity)
        } else if controller.isBuffering && controller.status != .opening {
            ProgressView().controlSize(.large).frame(maxHeight: .infinity)
        } else if controller.status == .opening {
            ProgressView("Opening…").frame(maxHeight: .infinity)
        }
    }
}

private struct ControlBar: View {
    let controller: PlaybackController
    let ui: PlayerUIState

    var body: some View {
        VStack(spacing: 6) {
            if let warning = controller.warning {
                Text(warning).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 14) {
                Button(action: controller.togglePlayPause) {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 28)
                }
                .buttonStyle(.plain)

                Text(Formatting.time(controller.displayedTime))
                    .monospacedDigit().font(.callout)

                SeekBar(controller: controller)

                Text("-" + Formatting.time(max(0, controller.duration - controller.displayedTime)))
                    .monospacedDigit().font(.callout).foregroundStyle(.secondary)

                Button { ui.toggleFullScreen?() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: 960)
        .onHover { ui.isInteracting = $0 }
    }
}

/// Thin scrubber. Dragging previews with keyframe seeks; releasing seeks accurately.
struct SeekBar: View {
    let controller: PlaybackController
    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let fraction = controller.duration > 0 ? controller.displayedTime / controller.duration : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: 5)
                Capsule().fill(.white).frame(width: width * CGFloat(min(max(fraction, 0), 1)), height: 5)
                Circle().fill(.white).frame(width: 13, height: 13)
                    .offset(x: width * CGFloat(min(max(fraction, 0), 1)) - 6.5)
                    .opacity(controller.scrubPosition != nil || hoverX != nil ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in controller.scrub(to: time(at: value.location.x, width: width)) }
                .onEnded { value in controller.endScrub(at: time(at: value.location.x, width: width)) })
            .onContinuousHover { phase in
                if case .active(let p) = phase { hoverX = p.x } else { hoverX = nil }
            }
            .overlay(alignment: .topLeading) {
                if let x = hoverX, controller.duration > 0 {
                    Text(Formatting.time(time(at: x, width: width)))
                        .font(.caption).monospacedDigit()
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                        .offset(x: min(max(0, x - 24), width - 48), y: -26)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 22)
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        Double(min(max(0, x / width), 1)) * controller.duration
    }
}
