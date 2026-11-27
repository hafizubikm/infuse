import AppKit
import AVFoundation
import SwiftUI

/// Hosts the video layer (and later the subtitle layer) with the SwiftUI controls on top.
/// Tracks the mouse to show/hide the controls and cursor.
final class PlayerView: NSView {
    let controller: PlaybackController
    let ui: PlayerUIState
    private let videoLayer: AVSampleBufferDisplayLayer
    private var hostingView: NSHostingView<ControlsOverlay>!
    private var hideTimer: Timer?

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
    @ObservationIgnored var onActivity: (() -> Void)?
    @ObservationIgnored var toggleFullScreen: (() -> Void)?
}
