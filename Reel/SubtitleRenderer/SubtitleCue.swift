import Foundation

/// A decoded bitmap subtitle rectangle (PGS / VobSub / DVB), as straight RGBA.
struct SubtitleBitmap: Equatable, Sendable {
    var x: Int, y: Int, width: Int, height: Int
    /// width × height × 4 bytes, RGBA, not premultiplied.
    var rgba: [UInt8]
    var forced: Bool
}

enum SubtitleContent: Equatable, Sendable {
    case text([ASSEvent])
    /// Rectangles in canvas coordinates (canvasWidth × canvasHeight).
    case bitmaps([SubtitleBitmap], canvasWidth: Int, canvasHeight: Int)
}

struct SubtitleCue: Equatable, Sendable {
    var start: Double
    /// nil while open-ended (PGS cues end when the next display set arrives).
    var end: Double?
    var content: SubtitleContent

    var isForced: Bool {
        if case .bitmaps(let rects, _, _) = content { return !rects.isEmpty && rects.allSatisfy(\.forced) }
        return false
    }

    func isActive(at t: Double) -> Bool {
        t >= start && t < (end ?? .greatestFiniteMagnitude)
    }
}

/// Time-ordered cues of one subtitle track. Thread-safe.
final class CueStore: @unchecked Sendable {
    private let lock = NSLock()
    private var cues: [SubtitleCue] = []
    /// Incremented on every change so renderers can skip redundant work.
    private(set) var version = 0
    /// Longest plausible cue; also how far back lookups scan.
    static let maxCueDuration = 30.0

    var count: Int { lock.lock(); defer { lock.unlock() }; return cues.count }

    func add(_ cue: SubtitleCue) {
        lock.lock(); defer { lock.unlock() }
        // Skip duplicates (packets are re-read after seeking backwards).
        let lo = lowerBound(cue.start - 0.002)
        var i = lo
        while i < cues.count, cues[i].start <= cue.start + 0.002 {
            if cues[i].content == cue.content { return }
            i += 1
        }
        // Bitmap formats signal the end of a cue with the next display set: close open cues.
        if case .bitmaps = cue.content {
            for j in stride(from: lo - 1, through: max(0, lo - 8), by: -1) where cues[j].end == nil {
                cues[j].end = cue.start
            }
        }
        let insertAt = lowerBound(cue.start + 0.0001)
        if case .bitmaps(let rects, _, _) = cue.content, rects.isEmpty {
            // An empty display set only clears; don't store it.
            version += 1
            return
        }
        cues.insert(cue, at: insertAt)
        version += 1
    }

    /// Cues showing at `t`, in start order.
    func active(at t: Double) -> [SubtitleCue] {
        lock.lock(); defer { lock.unlock() }
        let hi = lowerBound(t + 0.0001)
        var result: [SubtitleCue] = []
        var i = hi - 1
        while i >= 0, cues[i].start >= t - Self.maxCueDuration {
            if cues[i].isActive(at: t) { result.append(cues[i]) }
            i -= 1
        }
        return result.reversed()
    }

    /// Forgets cues that ended well before `t` (keeps memory bounded for long bitmap tracks).
    func prune(before t: Double) {
        lock.lock(); defer { lock.unlock() }
        let cutoff = t - 60
        guard let first = cues.first, first.start < cutoff else { return }
        cues.removeAll { ($0.end ?? .greatestFiniteMagnitude) < cutoff }
    }

    func removeAll() {
        lock.lock(); cues.removeAll(); version += 1; lock.unlock()
    }

    private func lowerBound(_ t: Double) -> Int {
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].start < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
