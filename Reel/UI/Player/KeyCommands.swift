import AppKit

/// Player keyboard shortcuts.
///   Space play/pause · ←/→ ±10 s · ⇧←/→ ±60 s · ↑/↓ volume · F full screen · M mute · Esc exit full screen
///   I info overlay · S cycle subtitles · (A audio arrives with milestone 6.)
@MainActor
enum KeyCommands {
    static func handle(_ event: NSEvent, controller: PlaybackController, ui: PlayerUIState, window: NSWindow?) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Leave ⌘-shortcuts (⌘W, ⌘Q, ⌘O …) to the menu.
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) { return false }
        let shift = flags.contains(.shift)

        switch event.keyCode {
        case 49:  // space
            controller.togglePlayPause()
        case 123: // ←
            controller.skip(by: shift ? -60 : -10)
        case 124: // →
            controller.skip(by: shift ? 60 : 10)
        case 126: // ↑
            controller.setVolume(controller.volume + 0.1)
        case 125: // ↓
            controller.setVolume(controller.volume - 0.1)
        case 53:  // esc
            guard let window, window.styleMask.contains(.fullScreen) else { return false }
            window.toggleFullScreen(nil)
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "f": window?.toggleFullScreen(nil)
            case "m": controller.setMuted(!controller.isMuted)
            case "i": ui.showInfo.toggle()
            case "s": controller.cycleSubtitles()
            default: return false
            }
        }
        ui.onActivity?()
        return true
    }
}
