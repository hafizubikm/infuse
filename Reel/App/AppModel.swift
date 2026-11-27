import AppKit
import Observation

/// App-wide state and the entry point for every way of opening a file
/// (library, drag and drop, File › Open, "Open With", double-click in Finder).
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    /// Resume points, recents and per-file track choices.
    @ObservationIgnored let history = PlaybackHistory()
    /// Incremented when history changes, so library views refresh.
    private(set) var historyVersion = 0

    /// "Get Info" sheet state.
    enum InspectorState: Sendable {
        case loading(URL)
        case loaded(MediaInfo)
        case failed(URL, String)
    }
    var inspector: InspectorState?

    func open(_ urls: [URL]) {
        guard let url = urls.first(where: SupportedMedia.isVideo) ?? urls.first else { return }
        play(url)
    }

    /// Plays `url`, resuming where you left off (with the tracks you chose) unless `startOver`.
    func play(_ url: URL, startOver: Bool = false) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "“\(url.lastPathComponent)” isn't available"
            alert.informativeText = "The drive or folder that contains it isn't connected. Connect it and try again."
            alert.runModal()
            return
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        let identity = FileIdentity(url: url)
        let entry = history.entry(for: identity)
        let start = startOver ? 0 : (history.resumePosition(for: identity) ?? 0)
        let prefs = PlaybackController.Preferences(audioStreamIndex: entry?.audioStreamIndex,
                                                   subtitleTrackID: entry?.subtitleTrackID,
                                                   subtitlesOff: entry?.subtitlesOff ?? false)
        PlayerWindowController.open(url, startAt: start, history: history, preferences: prefs)
        historyChanged()
    }

    func historyChanged() { historyVersion += 1 }

    func forget(_ identity: FileIdentity) {
        history.remove(identity)
        historyChanged()
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SupportedMedia.openPanelTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a video to open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open([url])
    }

    /// Probes a file off the main thread for the "Get Info" sheet.
    func inspect(_ url: URL) {
        inspector = .loading(url)
        Task.detached(priority: .userInitiated) {
            let result: InspectorState
            do {
                result = .loaded(try MediaProbe.probe(url: url))
            } catch {
                result = .failed(url, String(describing: error))
            }
            await MainActor.run {
                if case .loading(let current) = AppModel.shared.inspector, current == url {
                    AppModel.shared.inspector = result
                }
            }
        }
    }
}
