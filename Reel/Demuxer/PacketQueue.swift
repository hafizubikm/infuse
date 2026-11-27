import Foundation
import CFFmpeg

/// A thread-safe FIFO of packets for one stream, between the demux thread (producer)
/// and a renderer feeder (consumer). Never blocks the consumer.
final class PacketQueue: @unchecked Sendable {
    let streamIndex: Int
    let timeBase: AVRational
    /// Subtitle and other sparse streams don't count towards "buffer full" decisions.
    let isSparse: Bool

    private let lock = NSLock()
    private var packets: [Packet] = []
    private var head = 0
    private var bytes = 0
    private var endOfStream = false
    private var availabilityHandlers: [() -> Void] = []
    private var packetHandlers: [() -> Void] = []

    /// Called (outside the lock) whenever a packet is consumed; the demuxer uses it to wake up.
    var onConsumed: (() -> Void)?

    init(streamIndex: Int, timeBase: AVRational, isSparse: Bool = false) {
        self.streamIndex = streamIndex
        self.timeBase = timeBase
        self.isSparse = isSparse
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return packets.count - head }
    var byteCount: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    var isEndOfStream: Bool { lock.lock(); defer { lock.unlock() }; return endOfStream }

    /// True once end of stream was signalled and every packet has been consumed.
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return endOfStream && head == packets.count }

    /// Seconds of media buffered (from first to last queued timestamp, plus the last duration).
    var bufferedSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        guard head < packets.count,
              let first = packets[head].bestTimestamp,
              let last = packets[packets.count - 1].bestTimestamp
        else { return 0 }
        let span = Double(max(0, last - first) + packets[packets.count - 1].duration)
        return span * timeBase.doubleValue
    }

    func push(_ packet: Packet) {
        lock.lock()
        packets.append(packet)
        bytes += packet.size
        let handlers = takeHandlersLocked() + packetHandlers
        packetHandlers.removeAll()
        lock.unlock()
        handlers.forEach { $0() }
    }

    func pop() -> Packet? {
        lock.lock()
        guard head < packets.count else { lock.unlock(); return nil }
        let p = packets[head]
        head += 1
        bytes -= p.size
        compactLocked()
        lock.unlock()
        onConsumed?()
        return p
    }

    func peek() -> Packet? {
        lock.lock(); defer { lock.unlock() }
        return head < packets.count ? packets[head] : nil
    }

    func markEndOfStream() {
        lock.lock()
        endOfStream = true
        let handlers = takeHandlersLocked()
        lock.unlock()
        handlers.forEach { $0() }
    }

    /// Drops all packets and clears end-of-stream (after a seek).
    func flush() {
        lock.lock()
        packets.removeAll(keepingCapacity: true)
        head = 0
        bytes = 0
        endOfStream = false
        lock.unlock()
        onConsumed?()
    }

    /// Runs `handler` once, as soon as a packet (or end of stream) is available.
    /// Runs it immediately, on the calling thread, if one already is.
    func whenAvailable(_ handler: @escaping () -> Void) {
        lock.lock()
        if head < packets.count || endOfStream {
            lock.unlock()
            handler()
            return
        }
        availabilityHandlers.append(handler)
        lock.unlock()
    }

    /// Runs `handler` once, as soon as a packet is available (end of stream does not count).
    /// Runs it immediately, on the calling thread, if one already is.
    func whenPacketAvailable(_ handler: @escaping () -> Void) {
        lock.lock()
        if head < packets.count {
            lock.unlock()
            handler()
            return
        }
        packetHandlers.append(handler)
        lock.unlock()
    }

    private func takeHandlersLocked() -> [() -> Void] {
        let h = availabilityHandlers
        availabilityHandlers.removeAll()
        return h
    }

    private func compactLocked() {
        if head > 256 && head * 2 > packets.count {
            packets.removeFirst(head)
            head = 0
        }
    }
}
