import Foundation
import CFFmpeg

/// Reads packets on a dedicated thread and distributes them to per-stream `PacketQueue`s.
///
/// - Reads ahead until every non-sparse queue holds `targetBufferSeconds` of media, or the total
///   buffered bytes exceed `maxBufferedBytes` (so a badly interleaved file cannot starve a stream).
/// - Seeks are requested from any thread and performed on the demux thread; the newest request
///   wins. After a seek, all queues are flushed and `generation` is incremented.
/// - All file I/O happens on the demux thread, never on the main thread.
final class Demuxer: @unchecked Sendable {
    enum Event {
        case endOfFile
        case error(DemuxError)
    }

    enum DemuxError: Error, CustomStringConvertible {
        case driveDisconnected(URL)
        case readFailed(FFmpegError)

        var description: String {
            switch self {
            case .driveDisconnected(let url):
                return "The drive containing “\(url.lastPathComponent)” is no longer available."
            case .readFailed(let e):
                return "Reading the file failed: \(FFmpegError.message(for: e.code))"
            }
        }
    }

    struct SeekResult {
        let generation: Int
        let target: Double
        let succeeded: Bool
    }

    let file: MediaFile
    var targetBufferSeconds = 3.0
    var maxBufferedBytes = 256 << 20

    /// Called on the demux thread.
    var onEvent: ((Event) -> Void)?

    private let condition = NSCondition()
    private var queues: [Int: PacketQueue] = [:]
    private var thread: Thread?
    private var stopRequested = false
    private var pendingSeek: (target: Double, completion: (SeekResult) -> Void)?
    private var reachedEOF = false
    private var failed = false
    private var _generation = 0
    private let finished = DispatchSemaphore(value: 0)

    var generation: Int { condition.lock(); defer { condition.unlock() }; return _generation }

    init(file: MediaFile) {
        self.file = file
    }

    // MARK: - Configuration (call before start or while running)

    /// Selects which streams are read into queues; all others are discarded by FFmpeg.
    func setActiveStreams(_ indices: Set<Int>) {
        condition.lock()
        let ctx = file.formatContext
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let st = ctx.pointee.streams[i] else { continue }
            if indices.contains(i) {
                st.pointee.discard = AVDISCARD_DEFAULT
                if queues[i] == nil {
                    let sparse = st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE
                    let q = PacketQueue(streamIndex: i, timeBase: st.pointee.time_base, isSparse: sparse)
                    q.onConsumed = { [weak self] in self?.wake() }
                    queues[i] = q
                }
            } else {
                st.pointee.discard = AVDISCARD_ALL
                queues[i] = nil
            }
        }
        condition.unlock()
    }

    func queue(for streamIndex: Int) -> PacketQueue? {
        condition.lock(); defer { condition.unlock() }
        return queues[streamIndex]
    }

    // MARK: - Lifecycle

    func start() {
        condition.lock()
        guard thread == nil else { condition.unlock(); return }
        let t = Thread { [weak self] in self?.run() }
        t.name = "Reel.Demuxer"
        t.qualityOfService = .userInitiated
        thread = t
        condition.unlock()
        t.start()
    }

    /// Stops the thread and waits (briefly) for it to exit.
    func stop() {
        condition.lock()
        let wasRunning = thread != nil && !stopRequested
        stopRequested = true
        condition.broadcast()
        condition.unlock()
        file.abort()
        if wasRunning { _ = finished.wait(timeout: .now() + 2) }
    }

    /// Requests a seek to `target` seconds (media time, 0 = start of file). The completion runs
    /// on the demux thread after queues were flushed. Superseded requests never complete.
    func seek(to target: Double, completion: @escaping (SeekResult) -> Void) {
        condition.lock()
        pendingSeek = (target, completion)
        condition.broadcast()
        condition.unlock()
    }

    private func wake() {
        condition.lock()
        condition.signal()
        condition.unlock()
    }

    // MARK: - Demux thread

    private func run() {
        defer { finished.signal() }
        guard let packet = av_packet_alloc() else { return }
        var pkt: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&pkt) }
        var consecutiveErrors = 0

        while true {
            condition.lock()
            if stopRequested { condition.unlock(); return }
            if let seek = pendingSeek {
                pendingSeek = nil
                condition.unlock()
                performSeek(seek.target, completion: seek.completion)
                continue
            }
            if reachedEOF || failed || isBufferFullLocked() {
                _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1))
                condition.unlock()
                continue
            }
            let generation = _generation
            condition.unlock()

            let ret = av_read_frame(file.formatContext, packet)
            if ret == reel_averror_eagain() { continue }
            let atEndOfInput = file.formatContext.pointee.pb.map { avio_feof($0) != 0 } ?? false
            if ret == reel_averror_eof() || (ret < 0 && atEndOfInput && (file.io?.lastErrno ?? 0) == 0) {
                markEOF()
                continue
            }
            if ret < 0 {
                if file.io?.isAborted == true { return }
                if file.io?.deviceDisappeared == true {
                    fail(.driveDisconnected(file.url))
                    continue
                }
                consecutiveErrors += 1
                Log.demux.error("av_read_frame: \(FFmpegError.message(for: ret), privacy: .public)")
                if consecutiveErrors > 50 { fail(.readFailed(FFmpegError(code: ret, context: "av_read_frame"))) }
                continue
            }
            consecutiveErrors = 0

            let index = Int(packet.pointee.stream_index)
            condition.lock()
            let queue = queues[index]
            // A seek that arrived while reading invalidates this packet.
            let stale = generation != _generation || pendingSeek != nil
            condition.unlock()
            if let queue, !stale, let p = Packet(moving: packet, generation: generation) {
                queue.push(p)
            } else {
                av_packet_unref(packet)
            }
        }
    }

    private func isBufferFullLocked() -> Bool {
        let active = queues.values.filter { !$0.isSparse }
        guard !active.isEmpty else { return false }
        let totalBytes = queues.values.reduce(0) { $0 + $1.byteCount }
        if totalBytes >= maxBufferedBytes { return true }
        return active.allSatisfy { $0.bufferedSeconds >= targetBufferSeconds }
    }

    private func performSeek(_ target: Double, completion: (SeekResult) -> Void) {
        let ctx = file.formatContext
        let ts = Int64(max(0, target) * Double(AV_TIME_BASE)) + file.startTime
        var ret = avformat_seek_file(ctx, -1, Int64.min, ts, ts, 0)
        if ret < 0 {
            ret = av_seek_frame(ctx, -1, ts, AVSEEK_FLAG_BACKWARD)
        }
        if ret < 0 {
            Log.demux.error("Seek to \(target) failed: \(FFmpegError.message(for: ret), privacy: .public)")
        }
        condition.lock()
        _generation += 1
        let generation = _generation
        reachedEOF = false
        if file.io?.deviceDisappeared != true { failed = false }
        let all = Array(queues.values)
        condition.unlock()
        all.forEach { $0.flush() }
        completion(SeekResult(generation: generation, target: target, succeeded: ret >= 0))
    }

    private func markEOF() {
        condition.lock()
        reachedEOF = true
        let all = Array(queues.values)
        condition.unlock()
        all.forEach { $0.markEndOfStream() }
        onEvent?(.endOfFile)
    }

    private func fail(_ error: DemuxError) {
        condition.lock()
        failed = true
        condition.unlock()
        Log.demux.error("\(error.description, privacy: .public)")
        onEvent?(.error(error))
    }
}
