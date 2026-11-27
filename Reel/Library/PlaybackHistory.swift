import Foundation

/// Where Reel keeps its data: ~/Library/Application Support/Reel
enum ReelStorage {
    static var directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Reel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let writeQueue = DispatchQueue(label: "Reel.Storage", qos: .utility)

    static func load<T: Decodable>(_ type: T.Type, from name: String, in directory: URL = directory) -> T? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    /// Writes atomically on a background queue.
    static func save<T: Encodable>(_ value: T, to name: String, in directory: URL = directory, sync: Bool = false) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        let url = directory.appendingPathComponent(name)
        let write = { try? data.write(to: url, options: .atomic) }
        if sync { writeQueue.sync { _ = write() } } else { writeQueue.async { _ = write() } }
    }
}

/// What Reel remembers about a file you've played.
struct HistoryEntry: Codable, Equatable, Sendable {
    var identity: FileIdentity
    /// Where the file was last seen.
    var url: URL
    var title: String
    var position: Double
    var duration: Double
    var lastPlayed: Date
    var finished: Bool
    /// The audio stream and subtitle track chosen last time (nil = automatic / off).
    var audioStreamIndex: Int?
    var subtitleTrackID: String?
    var subtitlesOff: Bool?

    var progress: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
    var remaining: Double { max(0, duration - position) }
}

/// Resume points, Recently Played and Continue Watching. Persisted as JSON.
final class PlaybackHistory: @unchecked Sendable {
    /// Minimum position worth resuming from, and the fraction counted as "watched".
    static let minimumResume = 30.0
    static let finishedFraction = 0.95

    private let lock = NSLock()
    private var entries: [String: HistoryEntry]
    private let fileName: String
    private let directory: URL

    init(directory: URL = ReelStorage.directory, fileName: String = "history.json") {
        self.directory = directory
        self.fileName = fileName
        let list = ReelStorage.load([HistoryEntry].self, from: fileName, in: directory) ?? []
        entries = Dictionary(list.map { ($0.identity.key, $0) }, uniquingKeysWith: { a, b in a.lastPlayed > b.lastPlayed ? a : b })
    }

    func entry(for identity: FileIdentity) -> HistoryEntry? {
        lock.lock(); defer { lock.unlock() }
        return entries[identity.key]
    }

    /// Where to start playing: the saved position if it is worth resuming.
    func resumePosition(for identity: FileIdentity) -> Double? {
        guard let e = entry(for: identity), !e.finished, e.position >= Self.minimumResume,
              e.duration <= 0 || e.position < e.duration * Self.finishedFraction else { return nil }
        return e.position
    }

    /// Records progress (call periodically while playing, and on pause / close).
    func record(identity: FileIdentity, url: URL, title: String, position: Double, duration: Double,
                audioStreamIndex: Int? = nil, subtitleTrackID: String?? = nil, now: Date = Date()) {
        lock.lock()
        var e = entries[identity.key] ?? HistoryEntry(identity: identity, url: url, title: title, position: 0,
                                                       duration: duration, lastPlayed: now, finished: false)
        e.url = url
        e.title = title
        e.position = position
        if duration > 0 { e.duration = duration }
        e.lastPlayed = now
        e.finished = e.duration > 0 && position >= e.duration * Self.finishedFraction
        if let audioStreamIndex { e.audioStreamIndex = audioStreamIndex }
        if let choice = subtitleTrackID {
            e.subtitleTrackID = choice
            e.subtitlesOff = choice == nil
        }
        entries[identity.key] = e
        lock.unlock()
        scheduleSave()
    }

    func remove(_ identity: FileIdentity) {
        lock.lock(); entries[identity.key] = nil; lock.unlock()
        scheduleSave()
    }

    /// Most recently played first.
    func recentlyPlayed(limit: Int = 50) -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        return Array(entries.values.sorted { $0.lastPlayed > $1.lastPlayed }.prefix(limit))
    }

    /// Started but not finished, most recent first.
    func continueWatching(limit: Int = 30) -> [HistoryEntry] {
        recentlyPlayed(limit: 500).filter {
            !$0.finished && $0.position >= Self.minimumResume
        }.prefix(limit).map { $0 }
    }

    func saveNow() {
        lock.lock(); let list = Array(entries.values); lock.unlock()
        ReelStorage.save(list, to: fileName, in: directory, sync: true)
    }

    private var saveScheduled = false
    private func scheduleSave() {
        lock.lock()
        guard !saveScheduled else { lock.unlock(); return }
        saveScheduled = true
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.saveScheduled = false
            let list = Array(self.entries.values)
            self.lock.unlock()
            ReelStorage.save(list, to: self.fileName, in: self.directory)
        }
    }
}
