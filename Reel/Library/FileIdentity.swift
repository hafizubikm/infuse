import Foundation

/// A stable key for a media file: the volume's UUID plus the path inside that volume, so resume
/// points and library entries survive an external SSD being mounted at a different path
/// ("/Volumes/SSD" vs "/Volumes/SSD 1"). Falls back to the absolute path.
struct FileIdentity: Hashable, Codable, Sendable, CustomStringConvertible {
    let key: String

    var description: String { key }

    init(key: String) { self.key = key }

    init(url: URL) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        #if os(macOS)
        if let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey]),
           let uuid = values.volumeUUIDString, let volume = values.volume {
            let root = volume.standardizedFileURL.resolvingSymlinksInPath().path
            var relative = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
            if !relative.hasPrefix("/") { relative = "/" + relative }
            key = "\(uuid):\(relative)"
            return
        }
        #endif
        key = "path:\(path)"
    }
}
