import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// The file types Reel opens, by extension.
enum SupportedMedia {
    static let videoExtensions: Set<String> = [
        "mkv", "mk3d", "webm",
        "mp4", "m4v", "mov",
        "avi",
        "ts", "m2ts", "mts", "m2t",
        "mpg", "mpeg", "vob",
        "wmv", "asf", "flv", "ogv", "3gp",
    ]

    static let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "vtt"]

    static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    #if canImport(UniformTypeIdentifiers)
    /// Content types for NSOpenPanel. Unknown extensions (e.g. mkv on a system without a
    /// Matroska UTI) still get a dynamic type, so the panel accepts them.
    static var openPanelTypes: [UTType] {
        var types: [UTType] = [.movie, .video, .audiovisualContent]
        for ext in videoExtensions.sorted() {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }
    #endif
}
