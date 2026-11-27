import AppKit
import Observation

/// The library: folders you added (remembered with bookmarks, so an external SSD is found again
/// after remounting or renaming) and the videos found in them. Persisted as JSON.
@MainActor
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    struct Folder: Codable, Identifiable, Equatable {
        var id = UUID()
        var bookmark: Data
        /// Last resolved location (shown when the drive is offline).
        var path: String
        var name: String
    }

    private struct Persisted: Codable {
        var folders: [Folder]
        var items: [MediaItem]
    }

    private(set) var folders: [Folder] = []
    private(set) var items: [MediaItem] = []
    /// Folders whose drive is currently not mounted.
    private(set) var offlineFolders: Set<UUID> = []
    private(set) var scanning = false
    private(set) var scanProgress: (done: Int, total: Int) = (0, 0)

    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    private init() {
        if let saved = ReelStorage.load(Persisted.self, from: "library.json") {
            folders = saved.folders
            items = saved.items
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { LibraryStore.shared.rescan() }
            })
        }
    }

    // MARK: - Queries

    func items(in folderID: UUID) -> [MediaItem] { items.filter { $0.folderID == folderID } }

    func item(for identity: FileIdentity) -> MediaItem? { items.first { $0.identity == identity } }

    /// False when the item's drive is offline (no file-system access, so it's cheap for big lists).
    func isAvailable(_ item: MediaItem) -> Bool {
        guard let f = item.folderID else { return true }
        return !offlineFolders.contains(f)
    }

    // MARK: - Folders

    func presentAddFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Library"
        panel.message = "Choose folders with videos (for example on your external SSD)"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(addFolder)
    }

    func addFolder(_ url: URL) {
        guard !folders.contains(where: { $0.path == url.path }) else { return }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            folders.append(Folder(bookmark: bookmark, path: url.path, name: url.lastPathComponent))
            save()
            rescan()
        } catch {
            Log.library.error("Can't bookmark \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func removeFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        items.removeAll { $0.folderID == id }
        save()
    }

    // MARK: - Scanning

    /// Re-resolves every folder and scans the ones that are online (in the background).
    func rescan() {
        scanTask?.cancel()
        let snapshot = folders
        let cached = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        scanning = true
        scanTask = Task { [weak self] in
            var found: [UUID: [MediaItem]] = [:]
            var offline: Set<UUID> = []
            var updatedFolders = snapshot
            for (i, folder) in snapshot.enumerated() {
                guard let url = Self.resolve(folder, updating: &updatedFolders[i]) else {
                    offline.insert(folder.id)
                    continue
                }
                let items = await LibraryScanner.scan(folder: url, folderID: folder.id, cached: cached) { done, total in
                    Task { @MainActor in self?.scanProgress = (done, total) }
                }
                if Task.isCancelled { return }
                found[folder.id] = items
            }
            guard let self, !Task.isCancelled else { return }
            // Keep the cached items of offline folders so they still show (greyed out).
            let kept = self.items.filter { $0.folderID.map(offline.contains) ?? false }
            self.items = kept + found.values.flatMap { $0 }
            self.offlineFolders = offline
            self.folders = updatedFolders
            self.scanning = false
            self.save()
            Log.library.notice("Library scan finished: \(self.items.count) videos, \(offline.count) offline folders")
        }
    }

    /// Resolves a folder bookmark; refreshes stale bookmarks. Nil if the volume isn't mounted.
    private nonisolated static func resolve(_ folder: Folder, updating copy: inout Folder) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: folder.bookmark, options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        if stale, let fresh = try? url.bookmarkData() { copy.bookmark = fresh }
        copy.path = url.path
        return url
    }

    private func save() {
        ReelStorage.save(Persisted(folders: folders, items: items), to: "library.json")
    }
}
