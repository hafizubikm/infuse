import SwiftUI

enum SidebarItem: Hashable {
    case continueWatching, recent, all
    case folder(UUID)
}

/// The main window: library sidebar + list/grid of videos. Drop files anywhere to play them.
struct LibraryView: View {
    let model: AppModel
    @Bindable private var library = LibraryStore.shared
    @State private var selection: SidebarItem? = .continueWatching
    @State private var search = ""
    @AppStorage("library.grid") private var gridLayout = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            detail
                .searchable(text: $search, placement: .toolbar, prompt: "Search")
        }
        .toolbar {
            ToolbarItem {
                Picker("View", selection: $gridLayout) {
                    Image(systemName: "list.bullet").tag(false)
                    Image(systemName: "square.grid.2x2").tag(true)
                }
                .pickerStyle(.segmented)
                .help("List or grid")
            }
            ToolbarItem {
                Button { library.rescan() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Rescan folders")
                    .disabled(library.folders.isEmpty)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let videos = urls.filter(SupportedMedia.isVideo)
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            folders.forEach(library.addFolder)
            if !videos.isEmpty { model.open(videos) }
            return !videos.isEmpty || !folders.isEmpty
        }
        .sheet(isPresented: Binding(get: { model.inspector != nil }, set: { if !$0 { model.inspector = nil } })) {
            StreamInspectorSheet(model: model)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Watch") {
                Label("Continue Watching", systemImage: "play.circle").tag(SidebarItem.continueWatching)
                Label("Recently Played", systemImage: "clock").tag(SidebarItem.recent)
            }
            Section("Library") {
                Label("All Videos", systemImage: "film.stack").tag(SidebarItem.all)
                ForEach(library.folders) { folder in
                    let offline = library.offlineFolders.contains(folder.id)
                    Label(folder.name, systemImage: offline ? "externaldrive.badge.xmark" : "folder")
                        .foregroundStyle(offline ? .secondary : .primary)
                        .help(offline ? "\(folder.path) — drive not connected" : folder.path)
                        .tag(SidebarItem.folder(folder.id))
                        .contextMenu {
                            Button("Show in Finder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
                            }
                            Button("Remove from Library", role: .destructive) { library.removeFolder(folder.id) }
                        }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                if library.scanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(library.scanProgress.total > 0
                             ? "Scanning \(library.scanProgress.done)/\(library.scanProgress.total)…" : "Scanning…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button { library.presentAddFolderPanel() } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        switch selection ?? .continueWatching {
        case .continueWatching:
            HistoryList(model: model, entries: filtered(model.history.continueWatching()), showProgress: true,
                        emptyTitle: "Nothing in progress", emptyMessage: "Videos you stop part-way through appear here.")
                .navigationTitle("Continue Watching")
                .id(model.historyVersion)
        case .recent:
            HistoryList(model: model, entries: filtered(model.history.recentlyPlayed()), showProgress: false,
                        emptyTitle: "Nothing played yet", emptyMessage: "Open a video, or drop one here.")
                .navigationTitle("Recently Played")
                .id(model.historyVersion)
        case .all:
            itemsView(filtered(library.items), title: "All Videos")
        case .folder(let id):
            itemsView(filtered(library.items(in: id)),
                      title: library.folders.first { $0.id == id }?.name ?? "Folder")
        }
    }

    @ViewBuilder private func itemsView(_ items: [MediaItem], title: String) -> some View {
        if library.folders.isEmpty {
            ContentUnavailableView {
                Label("Add your video folders", systemImage: "externaldrive")
            } description: {
                Text("Reel remembers the folders you add (for example on your external SSD) and lists the videos in them.")
            } actions: {
                Button("Add Folder…") { library.presentAddFolderPanel() }.buttonStyle(.borderedProminent)
            }
            .navigationTitle(title)
        } else if items.isEmpty {
            ContentUnavailableView(library.scanning ? "Scanning…" : (search.isEmpty ? "No videos" : "No matches"),
                                   systemImage: "film")
                .navigationTitle(title)
        } else if gridLayout {
            VideoGrid(model: model, items: items).navigationTitle(title)
        } else {
            VideoTable(model: model, items: items).navigationTitle(title)
        }
    }

    private func filtered(_ items: [MediaItem]) -> [MediaItem] {
        let sorted = items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        guard !search.isEmpty else { return sorted }
        return sorted.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }

    private func filtered(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        guard !search.isEmpty else { return entries }
        return entries.filter { $0.title.localizedCaseInsensitiveContains(search) }
    }
}

// MARK: - List / grid

private struct VideoTable: View {
    let model: AppModel
    let items: [MediaItem]
    @State private var selection = Set<MediaItem.ID>()

    var body: some View {
        Table(items, selection: $selection) {
            TableColumn("Name") { item in
                HStack(spacing: 6) {
                    Image(systemName: "film").foregroundStyle(.secondary)
                    Text(item.title).lineLimit(1)
                    if let entry = model.history.entry(for: item.identity), !entry.finished, entry.position > 30 {
                        ProgressView(value: entry.progress).frame(width: 40).controlSize(.mini)
                    }
                }
                .opacity(LibraryStore.shared.isAvailable(item) ? 1 : 0.4)
            }
            .width(min: 220, ideal: 380)
            TableColumn("Duration") { item in Text(Formatting.time(item.duration)).monospacedDigit() }
                .width(70)
            TableColumn("Resolution") { item in Text(item.resolutionLabel ?? "—") }
                .width(70)
            TableColumn("Format") { item in BadgeRow(item: item) }
                .width(min: 120, ideal: 160)
            TableColumn("Audio") { item in Text(item.audioSummary ?? "—").foregroundStyle(.secondary).lineLimit(1) }
                .width(min: 100, ideal: 150)
            TableColumn("Size") { item in Text(Formatting.fileSize(item.fileSize) ?? "") .foregroundStyle(.secondary) }
                .width(70)
        }
        .contextMenu(forSelectionType: MediaItem.ID.self) { ids in
            ItemMenu(model: model, items: items.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if let item = items.first(where: { ids.contains($0.id) }) { model.play(item.url) }
        }
    }
}

private struct VideoGrid: View {
    let model: AppModel
    let items: [MediaItem]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 18)], spacing: 18) {
                ForEach(items) { item in
                    VideoCard(item: item, entry: model.history.entry(for: item.identity))
                        .opacity(LibraryStore.shared.isAvailable(item) ? 1 : 0.4)
                        .onTapGesture(count: 2) { model.play(item.url) }
                        .contextMenu { ItemMenu(model: model, items: [item]) }
                }
            }
            .padding(20)
        }
    }
}

private struct VideoCard: View {
    let item: MediaItem
    let entry: HistoryEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [.gray.opacity(0.35), .gray.opacity(0.15)], startPoint: .top, endPoint: .bottom))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        VStack(spacing: 2) {
                            Image(systemName: "film").font(.title2).foregroundStyle(.secondary)
                            if let res = item.resolutionLabel { Text(res).font(.headline).foregroundStyle(.secondary) }
                        }
                    }
                if let entry, !entry.finished, entry.position > 30 {
                    GeometryReader { g in
                        Capsule().fill(.white.opacity(0.3)).frame(height: 4)
                            .overlay(alignment: .leading) {
                                Capsule().fill(Color.accentColor).frame(width: g.size.width * entry.progress, height: 4)
                            }
                    }
                    .frame(height: 4)
                    .padding(8)
                }
            }
            Text(item.title).font(.callout.weight(.medium)).lineLimit(2)
            HStack(spacing: 6) {
                Text(Formatting.time(item.duration)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                BadgeRow(item: item)
            }
        }
    }
}

/// "4K  DV  Atmos" badges.
struct BadgeRow: View {
    let item: MediaItem

    var body: some View {
        HStack(spacing: 4) {
            ForEach(item.badges, id: \.self) { BadgeView(text: $0) }
            if !item.readable { BadgeView(text: "Unreadable") }
        }
    }
}

private struct ItemMenu: View {
    let model: AppModel
    let items: [MediaItem]

    var body: some View {
        if let item = items.first {
            Button("Play") { model.play(item.url) }
            if model.history.resumePosition(for: item.identity) != nil {
                Button("Play from Beginning") { model.play(item.url, startOver: true) }
            }
            Divider()
            Button("Get Info") { model.inspect(item.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
            if model.history.entry(for: item.identity) != nil {
                Button("Forget Playback Position") { model.forget(item.identity) }
            }
        }
    }
}

// MARK: - History lists

private struct HistoryList: View {
    let model: AppModel
    let entries: [HistoryEntry]
    let showProgress: Bool
    let emptyTitle: String
    let emptyMessage: String

    var body: some View {
        if entries.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: showProgress ? "play.circle" : "clock",
                                   description: Text(emptyMessage))
        } else {
            List(entries, id: \.identity) { entry in
                HistoryRow(entry: entry, item: LibraryStore.shared.item(for: entry.identity), showProgress: showProgress)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.play(entry.url) }
                    .contextMenu {
                        Button("Play") { model.play(entry.url) }
                        Button("Play from Beginning") { model.play(entry.url, startOver: true) }
                        Button("Get Info") { model.inspect(entry.url) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                        Divider()
                        Button("Remove from History") { model.forget(entry.identity) }
                    }
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let item: MediaItem?
    let showProgress: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.finished ? "checkmark.circle.fill" : "play.circle")
                .font(.title2).foregroundStyle(entry.finished ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 8) {
                    if showProgress {
                        ProgressView(value: entry.progress).frame(width: 120).controlSize(.small)
                        Text("\(Formatting.time(entry.remaining)) left").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(entry.lastPlayed, style: .relative).font(.caption).foregroundStyle(.secondary)
                        Text("ago").font(.caption).foregroundStyle(.secondary)
                    }
                    if let item { BadgeRow(item: item) }
                }
            }
            Spacer()
            Text(Formatting.time(entry.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
