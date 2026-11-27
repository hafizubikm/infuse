import AppKit

/// Receives files opened from Finder ("Open With", double-click, drag onto the Dock icon).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        FFmpegLogging.install()
        _ = VideoFormatFactory.registerSupplementalDecoders
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            AppModel.shared.open(urls)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
