import Foundation
import CFFmpeg

/// A subtitle track the user can pick (embedded stream or external file).
struct SubtitleTrack: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case embedded(streamIndex: Int)
        case external(URL)
    }

    let id: String
    let source: Source
    let language: String?
    let title: String?
    /// Display name of the format: "SRT", "ASS", "PGS", "VobSub" …
    let format: String
    let isForced: Bool
    let isDefault: Bool
    let isHearingImpaired: Bool
    let isBitmap: Bool

    var isExternal: Bool { if case .external = source { return true } else { return false } }

    /// "English · SRT (Forced)", "Japanese · ASS · External"
    var menuTitle: String {
        var parts: [String] = []
        if let lang = Formatting.language(language) { parts.append(lang) }
        var format = self.format
        var flags: [String] = []
        if isForced { flags.append("Forced") }
        if isHearingImpaired { flags.append("SDH") }
        if !flags.isEmpty { format += " (\(flags.joined(separator: ", ")))" }
        parts.append(format)
        if let title, !title.isEmpty, !parts.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
            parts.append(title)
        }
        if isExternal { parts.append("External") }
        return parts.joined(separator: " · ")
    }
}

/// Owns subtitle decoding for one playing file: decodes every embedded subtitle stream as its
/// packets arrive (so switching tracks is instant), loads external files, and answers
/// "what should be on screen at time t" for the selected track. Thread-safe.
final class SubtitleManager: @unchecked Sendable {
    private let lock = NSLock()
    private var _tracks: [SubtitleTrack] = []
    private var stores: [String: CueStore] = [:]
    private var _selectedID: String?
    private var _forcedOnly = false
    private let pump = DispatchQueue(label: "Reel.Subtitles", qos: .userInitiated)
    private var decoders: [Int: SubtitleDecoder] = [:]          // pump queue only
    private var lastGeneration: [Int: Int] = [:]                // pump queue only

    /// Called (on an arbitrary queue) when tracks were added, e.g. external files finished loading.
    var onTracksChanged: (() -> Void)?

    var tracks: [SubtitleTrack] { lock.lock(); defer { lock.unlock() }; return _tracks }
    var selectedID: String? { lock.lock(); defer { lock.unlock() }; return _selectedID }
    var forcedOnly: Bool { lock.lock(); defer { lock.unlock() }; return _forcedOnly }

    /// Call `attach(_:)` once the demuxer has queues for `embeddedStreamIndices`.
    init(file: MediaFile) {
        for s in file.info.subtitleStreams {
            guard let st = file.stream(at: s.index) else { continue }
            let track = SubtitleTrack(
                id: "stream-\(s.index)", source: .embedded(streamIndex: s.index), language: s.language,
                title: s.title, format: s.codecDisplayName, isForced: s.isForced, isDefault: s.isDefault,
                isHearingImpaired: s.isHearingImpaired, isBitmap: s.subtitle?.isBitmap ?? false)
            do {
                let decoder = try SubtitleDecoder(stream: st, startTime: file.startTime)
                decoders[s.index] = decoder
                _tracks.append(track)
                stores[track.id] = CueStore()
            } catch {
                Log.subtitles.error("Can't decode subtitle stream \(s.index): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The embedded subtitle streams that should be demuxed.
    var embeddedStreamIndices: Set<Int> {
        Set(tracks.compactMap { if case .embedded(let i) = $0.source { return i } else { return nil } })
    }

    /// Starts draining the packet queue of an embedded stream (call after the demuxer has queues).
    func attach(_ demuxer: Demuxer) {
        for index in embeddedStreamIndices {
            if let queue = demuxer.queue(for: index) { drain(queue) }
        }
    }

    func loadExternal(for video: URL) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for candidate in ExternalSubtitles.find(for: video) {
                do {
                    let (cues, codec) = try ExternalSubtitles.load(candidate.url)
                    guard !cues.isEmpty else { continue }
                    let store = CueStore()
                    cues.forEach(store.add)
                    let track = SubtitleTrack(
                        id: "file-\(candidate.url.lastPathComponent)", source: .external(candidate.url),
                        language: candidate.language, title: nil, format: CodecNames.displayName(codec: codec),
                        isForced: candidate.forced, isDefault: false, isHearingImpaired: candidate.hearingImpaired,
                        isBitmap: false)
                    guard let self else { return }
                    self.lock.lock()
                    self._tracks.append(track)
                    self.stores[track.id] = store
                    self.lock.unlock()
                    Log.subtitles.notice("Loaded \(cues.count) cues from \(candidate.url.lastPathComponent, privacy: .public)")
                    self.onTracksChanged?()
                } catch {
                    Log.subtitles.error("Can't read \(candidate.url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    func select(_ id: String?, forcedOnly: Bool = false) {
        lock.lock()
        _selectedID = id
        _forcedOnly = forcedOnly
        lock.unlock()
    }

    /// Cues to show at `t` for the selected track, plus a version that changes with the store.
    func activeCues(at t: Double) -> [SubtitleCue] {
        lock.lock()
        let store = _selectedID.flatMap { stores[$0] }
        let forcedOnly = _forcedOnly
        lock.unlock()
        guard let store else { return [] }
        let cues = store.active(at: t)
        return forcedOnly ? cues.filter(\.isForced) : cues
    }

    func store(for id: String) -> CueStore? {
        lock.lock(); defer { lock.unlock() }
        return stores[id]
    }

    /// Keeps memory bounded for long bitmap tracks (call occasionally with the playback time).
    func prune(before t: Double) {
        lock.lock()
        let bitmapIDs = _tracks.filter { $0.isBitmap }.map(\.id)
        let s = bitmapIDs.compactMap { stores[$0] }
        lock.unlock()
        s.forEach { $0.prune(before: t) }
    }

    // MARK: - Decoding pump

    private func drain(_ queue: PacketQueue) {
        pump.async { [weak self] in
            guard let self else { return }
            let index = queue.streamIndex
            while let packet = queue.pop() {
                guard let decoder = self.decoders[index] else { continue }
                if self.lastGeneration[index] != packet.generation {
                    // After a seek: reset decoder state (PGS keeps palettes/objects between packets).
                    decoder.flush()
                    self.lastGeneration[index] = packet.generation
                }
                let cues = decoder.decode(packet)
                if !cues.isEmpty, let store = self.store(for: "stream-\(index)") {
                    cues.forEach(store.add)
                }
            }
            // Packets only: after end of stream a later seek delivers packets again.
            queue.whenPacketAvailable { [weak self] in self?.drain(queue) }
        }
    }
}

/// Chooses which subtitle track to show when a file opens.
enum SubtitleSelector {
    /// Forced subtitles in the audio's language (or with no language) first; then a track the file
    /// marks as default; otherwise none.
    static func defaultTrack(_ tracks: [SubtitleTrack], audioLanguage: String?) -> SubtitleTrack? {
        func sameLanguage(_ t: SubtitleTrack) -> Bool {
            guard let a = audioLanguage, let l = t.language else { return true }
            return a.prefix(2) == l.prefix(2)
        }
        if let forced = tracks.first(where: { $0.isForced && sameLanguage($0) }) { return forced }
        return tracks.first(where: \.isDefault)
    }
}
