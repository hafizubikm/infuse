import AppKit

/// Receives files opened from Finder ("Open With", double-click, drag onto the Dock icon).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        FFmpegLogging.install()
        _ = VideoFormatFactory.registerSupplementalDecoders
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in LibraryStore.shared.rescan() }
    }

    /// Clicking the Dock icon with no windows open shows the library again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.windows.first { $0.identifier?.rawValue == "library" }?.makeKeyAndOrderFront(nil) }
        return true
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
