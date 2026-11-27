import Foundation

/// One video in the library (a cached, compact summary of `MediaInfo`).
struct MediaItem: Codable, Identifiable, Equatable, Sendable {
    var identity: FileIdentity
    var url: URL
    var folderID: UUID?
    var fileSize: Int64
    var modified: Date
    var duration: Double?
    var width: Int?
    var height: Int?
    var videoCodec: String?
    /// "DV", "HDR10", "HLG", "Atmos", "DTS:X"
    var badges: [String]
    /// "E-AC-3 5.1 Atmos" etc. for the default audio track.
    var audioSummary: String?
    var hasSubtitles: Bool
    /// False when the file couldn't be read (shown as an error instead of being hidden).
    var readable: Bool

    var id: String { identity.key }
    var fileName: String { url.lastPathComponent }
    var title: String { url.deletingPathExtension().lastPathComponent }

    var resolutionLabel: String? {
        guard let w = width, let h = height else { return nil }
        return Formatting.resolutionClass(width: w, height: h)
    }

    init(identity: FileIdentity, url: URL, folderID: UUID?, fileSize: Int64, modified: Date, info: MediaInfo?) {
        self.identity = identity
        self.url = url
        self.folderID = folderID
        self.fileSize = fileSize
        self.modified = modified
        readable = info != nil
        duration = info?.duration
        let video = info?.primaryVideo
        width = video?.video?.width
        height = video?.video?.height
        videoCodec = video?.codecDisplayName
        badges = info?.badges ?? []
        audioSummary = info?.primaryAudio.map(TrackLabels.audioFormat)
        hasSubtitles = !(info?.subtitleStreams.isEmpty ?? true)
    }
}
