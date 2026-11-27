import AppKit
import Observation

/// App-wide state: what is open, and the entry point for every way of opening a file.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum InspectorState: Sendable {
        case empty
        case loading(URL)
        case loaded(MediaInfo)
        case failed(URL, String)
    }

    private(set) var inspector: InspectorState = .empty

    func open(_ urls: [URL]) {
        guard let url = urls.first(where: SupportedMedia.isVideo) ?? urls.first else { return }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        PlayerWindowController.open(url)
        inspect(url)
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

    /// Probes with FFmpeg off the main thread and shows the stream list in the main window.
    private func inspect(_ url: URL) {
        inspector = .loading(url)
        Task.detached(priority: .userInitiated) {
            let result: InspectorState
            do {
                result = .loaded(try MediaProbe.probe(url: url))
            } catch {
                result = .failed(url, String(describing: error))
            }
            await MainActor.run {
                // Ignore stale results if another file was opened meanwhile.
                if case .loading(let current) = AppModel.shared.inspector, current == url {
                    AppModel.shared.inspector = result
                }
            }
        }
    }
}
