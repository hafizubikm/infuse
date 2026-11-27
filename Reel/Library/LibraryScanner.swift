import Foundation

/// Finds videos in a folder (recursively) and probes new or changed ones with FFmpeg.
/// All file I/O happens off the main thread.
enum LibraryScanner {
    struct FileStat: Sendable {
        let url: URL
        let size: Int64
        let modified: Date
    }

    /// Video files under `folder`, skipping hidden files, bundles and files under `minimumSize`
    /// bytes (samples, broken downloads).
    static func videoFiles(in folder: URL, minimumSize: Int64 = 1_000_000) -> [FileStat] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [FileStat] = []
        for case let url as URL in enumerator where SupportedMedia.isVideo(url) {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let size = Int64(v.fileSize ?? 0)
            guard size >= minimumSize else { continue }
            result.append(FileStat(url: url, size: size, modified: v.contentModificationDate ?? .distantPast))
        }
        return result.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    /// Items for every video in `folder`. Unchanged files (same size and modification date) reuse
    /// `cached`; others are probed, `concurrency` at a time.
    static func scan(folder: URL, folderID: UUID, cached: [String: MediaItem], concurrency: Int = 4,
                     minimumSize: Int64 = 1_000_000,
                     progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> [MediaItem] {
        let files = videoFiles(in: folder, minimumSize: minimumSize)
        var results: [MediaItem] = []
        var toProbe: [(FileStat, FileIdentity)] = []
        for f in files {
            let identity = FileIdentity(url: f.url)
            if let old = cached[identity.key], old.fileSize == f.size,
               abs(old.modified.timeIntervalSince(f.modified)) < 1, old.readable {
                var item = old
                item.url = f.url
                item.folderID = folderID
                results.append(item)
            } else {
                toProbe.append((f, identity))
            }
        }
        let total = toProbe.count
        var done = 0
        progress(0, total)
        await withTaskGroup(of: MediaItem.self) { group in
            var next = 0
            func addNext() {
                guard next < toProbe.count else { return }
                let (file, identity) = toProbe[next]
                next += 1
                group.addTask {
                    let info = try? MediaProbe.probe(url: file.url, options: .fast)
                    return MediaItem(identity: identity, url: file.url, folderID: folderID,
                                     fileSize: file.size, modified: file.modified, info: info)
                }
            }
            for _ in 0..<min(concurrency, toProbe.count) { addNext() }
            for await item in group {
                results.append(item)
                done += 1
                progress(done, total)
                addNext()
            }
        }
        return results
    }
}
