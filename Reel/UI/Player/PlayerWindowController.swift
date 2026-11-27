import AppKit
import AVFoundation

/// The player window: black, title bar hidden in the content, sized to the video's aspect ratio.
/// One player at a time; opening another file replaces the current one.
@MainActor
final class PlayerWindowController: NSWindowController, NSWindowDelegate {
    private(set) static var current: PlayerWindowController?

    let controller: PlaybackController
    let ui = PlayerUIState()
    private var keyMonitor: Any?

    static func open(_ url: URL, startAt: Double = 0) {
        if let existing = current {
            existing.window?.close()   // windowWillClose tears the old one down
        }
        let wc = PlayerWindowController(url: url)
        current = wc
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        wc.controller.open(startAt: startAt, autoplay: true)
    }

    init(url: URL) {
        controller = PlaybackController(url: url)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(1280, screen.width * 0.7), height: min(720, screen.height * 0.7))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = url.lastPathComponent
        window.representedURL = url
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.isMovableByWindowBackground = true
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.minSize = NSSize(width: 480, height: 270)
        window.center()
        window.setFrameAutosaveName("ReelPlayerWindow")
        super.init(window: window)

        window.delegate = self
        window.contentView = PlayerView(controller: controller, ui: ui)
        ui.toggleFullScreen = { [weak window] in window?.toggleFullScreen(nil) }
        controller.onOpened = { [weak self] media in self?.fit(to: media.displaySize) }
        installKeyMonitor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Resizes the window to the video's display aspect ratio, within 80% of the screen.
    private func fit(to displaySize: CGSize?) {
        guard let window, let size = displaySize, size.width > 0, size.height > 0,
              !window.styleMask.contains(.fullScreen) else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let maxW = visible.width * 0.8, maxH = visible.height * 0.8
        let scale = min(1, min(maxW / size.width, maxH / size.height))
        let content = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        window.contentAspectRatio = size
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2)
        window.setFrame(frame, display: true, animate: false)
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return KeyCommands.handle(event, controller: self.controller, ui: self.ui, window: self.window) ? nil : event
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        controller.close()
        if Self.current === self { Self.current = nil }
    }

    func windowDidEnterFullScreen(_ notification: Notification) { ui.onActivity?() }
    func windowDidExitFullScreen(_ notification: Notification) { ui.onActivity?() }
}
