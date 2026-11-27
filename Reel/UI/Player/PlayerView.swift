import AppKit
import AVFoundation
import SwiftUI

/// Hosts the video layer and the subtitle overlay layer, with the SwiftUI controls on top.
/// Tracks the mouse to show/hide the controls and cursor.
final class PlayerView: NSView {
    let controller: PlaybackController
    let ui: PlayerUIState
    private let videoLayer: AVSampleBufferDisplayLayer
    private let subtitleLayer = SubtitleLayer()
    private var hostingView: NSHostingView<ControlsOverlay>!
    private var hideTimer: Timer?
    private var displayLink: CADisplayLink?
    private var lastPrune = Date()
    private var laidOutVideoSize: CGSize?

    init(controller: PlaybackController, ui: PlayerUIState) {
        self.controller = controller
        self.ui = ui
        videoLayer = controller.videoLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.frame = bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(videoLayer)
        layer?.addSublayer(subtitleLayer)

        hostingView = NSHostingView(rootView: ControlsOverlay(controller: controller, ui: ui))
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        ui.onActivity = { [weak self] in self?.userActivity() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        // Subtitles are timed against the playback clock every display refresh.
        let link = displayLink(target: self, selector: #selector(displayRefresh))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        subtitleLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    /// Stops the display link (it retains the view); call when the window closes.
    func tearDown() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func displayRefresh() {
        if laidOutVideoSize != controller.media?.displaySize { needsLayout = true }
        guard let subtitles = controller.subtitles else { return }
        let t = controller.preciseTime
        subtitleLayer.show(subtitles.activeCues(at: t), style: AppSettings.shared.subtitleStyle)
        if Date().timeIntervalSince(lastPrune) > 10 {
            lastPrune = Date()
            subtitles.prune(before: t)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
        subtitleLayer.contentsScale = window?.backingScaleFactor ?? 2
        subtitleLayer.layout(in: bounds, videoSize: controller.media?.displaySize)
        laidOutVideoSize = controller.media?.displaySize
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { userActivity() }
    override func mouseEntered(with event: NSEvent) { userActivity() }
    override func mouseExited(with event: NSEvent) { scheduleHide(after: 0.5) }

    /// Shows the controls and restarts the auto-hide timer.
    func userActivity() {
        if !ui.controlsVisible {
            withAnimation(.easeOut(duration: 0.15)) { ui.controlsVisible = true }
        }
        NSCursor.setHiddenUntilMouseMoves(false)
        scheduleHide(after: 3)
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideControlsIfIdle() }
        }
    }

    private func hideControlsIfIdle() {
        guard controller.isPlaying, !ui.isInteracting, controller.scrubPosition == nil else {
            scheduleHide(after: 3)
            return
        }
        withAnimation(.easeIn(duration: 0.3)) { ui.controlsVisible = false }
        if window?.isKeyWindow == true { NSCursor.setHiddenUntilMouseMoves(true) }
    }
}

/// View state shared between the AppKit player view and the SwiftUI controls.
@MainActor
@Observable
final class PlayerUIState {
    var controlsVisible = true
    /// True while the pointer is over the control bar (keeps it from hiding).
    var isInteracting = false
    var showInfo = false
    var pictureInPictureSupported = false
    @ObservationIgnored var onActivity: (() -> Void)?
    @ObservationIgnored var toggleFullScreen: (() -> Void)?
    @ObservationIgnored var togglePictureInPicture: (() -> Void)?
}
