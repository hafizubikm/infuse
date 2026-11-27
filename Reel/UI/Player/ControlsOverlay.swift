import SwiftUI

/// Minimal, auto-hiding player controls: transport, seek bar, track/speed menus, volume, PiP,
/// full screen, plus the resume banner, toasts and the info overlay.
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

            if let toast = controller.toast {
                Text(toast)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.7), in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 28)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if ui.showInfo {
                InfoOverlay(controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 40).padding(.leading, 24)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            VStack(alignment: .trailing, spacing: 10) {
                if let resumed = controller.resumedFrom {
                    ResumeBanner(time: resumed, startOver: controller.startOver, dismiss: controller.dismissResumeBanner)
                        .transition(.opacity)
                }
                if let device = controller.virtualSurroundOffer {
                    VirtualSurroundBanner(device: device, layout: currentLayout,
                                          accept: controller.acceptVirtualSurroundOffer,
                                          decline: controller.declineVirtualSurroundOffer,
                                          dismiss: controller.dismissVirtualSurroundOffer)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 28).padding(.trailing, 24)

            if ui.controlsVisible {
                ControlBar(controller: controller, ui: ui)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        // Drop another video onto the player to play it instead.
        .dropDestination(for: URL.self) { urls, _ in
            let videos = urls.filter(SupportedMedia.isVideo)
            guard !videos.isEmpty else { return false }
            AppModel.shared.open(videos)
            return true
        }
    }

    private var currentLayout: String {
        let track = controller.audioTracks.first { $0.index == controller.selectedAudioIndex }
        return track?.audio?.channelLayout ?? "\(track?.audio?.channels ?? 6)-channel"
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

                AudioMenu(controller: controller)
                SubtitleMenu(controller: controller)
                SpeedMenu(controller: controller)
                VolumeControl(controller: controller)

                if ui.pictureInPictureSupported {
                    Button { ui.togglePictureInPicture?() } label: {
                        Image(systemName: "pip.enter").font(.title3)
                    }
                    .buttonStyle(.plain)
                    .help("Picture in Picture")
                }

                Button { ui.toggleFullScreen?() } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right").font(.title3)
                }
                .buttonStyle(.plain)
                .help("Full Screen (F)")
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: 1100)
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

// MARK: - Menus and small controls

private struct AudioMenu: View {
    let controller: PlaybackController

    var body: some View {
        Menu {
            Section("Track") {
                ForEach(controller.audioTracks) { track in
                    Button {
                        controller.selectAudio(track.index)
                    } label: {
                        if track.index == controller.selectedAudioIndex {
                            Label(TrackLabels.menuTitle(track), systemImage: "checkmark")
                        } else {
                            Text(TrackLabels.menuTitle(track))
                        }
                    }
                }
            }
            Section("Sound") {
                ForEach(AudioMode.allCases) { mode in
                    let title = mode == .auto ? "Auto (\(controller.audioRendering.label))" : mode.label
                    Button {
                        controller.setAudioMode(mode)
                    } label: {
                        if mode == AppSettings.shared.audioMode {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            }
            Divider()
            SettingsLink { Text("Audio Settings…") }
        } label: {
            Image(systemName: "waveform").font(.title3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(controller.audioTracks.isEmpty)
        .help("Audio (A)")
    }
}

private struct SubtitleMenu: View {
    let controller: PlaybackController

    var body: some View {
        Menu {
            Button {
                controller.selectSubtitle(nil)
            } label: {
                if controller.selectedSubtitleID == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
            }
            Divider()
            ForEach(controller.subtitleTracks) { track in
                Button {
                    controller.selectSubtitle(track.id)
                } label: {
                    if track.id == controller.selectedSubtitleID {
                        Label(track.menuTitle, systemImage: "checkmark")
                    } else {
                        Text(track.menuTitle)
                    }
                }
            }
            Divider()
            SettingsLink { Text("Subtitle Style…") }
        } label: {
            Image(systemName: controller.selectedSubtitleID == nil ? "captions.bubble" : "captions.bubble.fill")
                .font(.title3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Subtitles (S)")
    }
}

private struct SpeedMenu: View {
    let controller: PlaybackController

    var body: some View {
        Menu {
            ForEach(PlaybackController.speeds, id: \.self) { speed in
                Button {
                    controller.setSpeed(speed)
                } label: {
                    if speed == controller.speed {
                        Label(PlaybackController.speedLabel(speed), systemImage: "checkmark")
                    } else {
                        Text(PlaybackController.speedLabel(speed))
                    }
                }
            }
        } label: {
            Text(PlaybackController.speedLabel(controller.speed))
                .font(.callout.weight(.semibold)).monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback speed")
    }
}

private struct VolumeControl: View {
    let controller: PlaybackController

    var body: some View {
        HStack(spacing: 6) {
            Button { controller.setMuted(!controller.isMuted) } label: {
                Image(systemName: icon).font(.callout).frame(width: 20)
            }
            .buttonStyle(.plain)
            .help("Mute (M)")
            Slider(value: Binding(get: { Double(controller.volume) },
                                  set: { controller.setVolume(Float($0)) }), in: 0...1)
                .frame(width: 80)
                .controlSize(.mini)
        }
    }

    private var icon: String {
        if controller.isMuted || controller.volume == 0 { return "speaker.slash.fill" }
        return controller.volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill"
    }
}

/// "Sony WH-1000XM5: use Virtual Surround?" — shown in Auto for non-Apple headphones.
private struct VirtualSurroundBanner: View {
    let device: AudioOutputDevice
    let layout: String
    let accept: () -> Void
    let decline: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "headphones").font(.title2).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 6) {
                Text("Use Virtual Surround for \(device.name)?")
                    .font(.callout.weight(.semibold)).foregroundStyle(.white)
                Text("Renders this \(layout) mix through virtual speakers around you, for headphones without Apple Spatial Audio. Reel remembers your answer for this device.")
                    .font(.caption).foregroundStyle(.white.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Use Virtual Surround", action: accept)
                        .buttonStyle(.borderedProminent)
                    Button("No Thanks", action: decline)
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                .help("Ask again next time")
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
    }
}

private struct ResumeBanner: View {
    let time: Double
    let startOver: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("Resumed at \(Formatting.time(time))")
                .font(.callout).foregroundStyle(.white)
            Button("Start Over", action: startOver)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.black.opacity(0.7), in: Capsule())
        .environment(\.colorScheme, .dark)
    }
}
