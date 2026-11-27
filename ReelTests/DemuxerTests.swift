import XCTest
import CFFmpeg
@testable import Reel

final class PacketQueueTests: XCTestCase {
    func testFIFOAvailabilityAndFlush() throws {
        let q = PacketQueue(streamIndex: 0, timeBase: AVRational(num: 1, den: 1000))
        var notified = 0
        q.whenAvailable { notified += 1 }
        XCTAssertEqual(notified, 0)

        let raw = try XCTUnwrap(av_packet_alloc())
        var rawOpt: UnsafeMutablePointer<AVPacket>? = raw
        defer { av_packet_free(&rawOpt) }
        for i in 0..<3 {
            XCTAssertEqual(av_new_packet(raw, 100), 0)
            raw.pointee.pts = Int64(i * 40)
            raw.pointee.duration = 40
            q.push(try XCTUnwrap(Packet(moving: raw, generation: 0)))
        }
        XCTAssertEqual(notified, 1)
        XCTAssertEqual(q.count, 3)
        XCTAssertEqual(q.byteCount, 300)
        XCTAssertEqual(q.bufferedSeconds, 0.12, accuracy: 0.0001)
        XCTAssertEqual(q.pop()?.pts, 0)
        XCTAssertEqual(q.peek()?.pts, 40)
        q.markEndOfStream()
        XCTAssertFalse(q.isFinished)
        q.flush()
        XCTAssertEqual(q.count, 0)
        XCTAssertFalse(q.isEndOfStream)
        var immediate = false
        q.markEndOfStream()
        q.whenAvailable { immediate = true }
        XCTAssertTrue(immediate)
        XCTAssertTrue(q.isFinished)
    }
}

final class DemuxerTests: XCTestCase {
    private func drain(_ q: PacketQueue, timeout: TimeInterval = 5) -> [Packet] {
        var out: [Packet] = []
        let deadline = Date().addingTimeInterval(timeout)
        while !q.isFinished && Date() < deadline {
            if let p = q.pop() { out.append(p) } else { usleep(1000) }
        }
        return out
    }

    func testReadsAllPacketsThroughCustomIO() throws {
        let file = try MediaFile(url: try TestMedia.url("hevc_hdr10_eac3.mkv"), useCustomIO: true)
        let info = file.info
        let v = try XCTUnwrap(info.primaryVideo).index
        let a = try XCTUnwrap(info.primaryAudio).index
        let demuxer = Demuxer(file: file)
        demuxer.setActiveStreams([v, a])
        demuxer.start()
        defer { demuxer.stop() }

        let vq = try XCTUnwrap(demuxer.queue(for: v))
        let aq = try XCTUnwrap(demuxer.queue(for: a))
        // Consume both queues concurrently so the read-ahead limit never blocks.
        final class Box: @unchecked Sendable { var packets: [Packet] = [] }
        let videoBox = Box(), audioBox = Box()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) { videoBox.packets = self.drain(vq) }
        DispatchQueue.global().async(group: group) { audioBox.packets = self.drain(aq) }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        let video = videoBox.packets, audio = audioBox.packets

        XCTAssertEqual(video.count, 72)                 // 3 s at 23.976 fps
        XCTAssertTrue(video.first?.isKeyframe ?? false)
        XCTAssertEqual(video.filter(\.isKeyframe).count, 3)
        XCTAssertGreaterThan(audio.count, 80)           // 3 s of 1536-sample E-AC-3 frames ≈ 94
        XCTAssertTrue(audio.allSatisfy { $0.generation == 0 })
    }

    func testSeekFlushesAndLandsOnKeyframeBeforeTarget() throws {
        let file = try MediaFile(url: try TestMedia.url("hevc_hdr10_eac3.mkv"), useCustomIO: true)
        let v = try XCTUnwrap(file.info.primaryVideo).index
        let demuxer = Demuxer(file: file)
        demuxer.setActiveStreams([v])
        demuxer.start()
        defer { demuxer.stop() }

        let done = expectation(description: "seek")
        var result: Demuxer.SeekResult?
        demuxer.seek(to: 1.5) { r in result = r; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(result?.generation, 1)
        XCTAssertEqual(result?.succeeded, true)

        let q = try XCTUnwrap(demuxer.queue(for: v))
        let deadline = Date().addingTimeInterval(5)
        var first: Packet?
        while first == nil && Date() < deadline { first = q.pop(); if first == nil { usleep(1000) } }
        let p = try XCTUnwrap(first)
        XCTAssertEqual(p.generation, 1)
        XCTAssertTrue(p.isKeyframe)
        let tb = try XCTUnwrap(file.stream(at: v)).pointee.time_base
        let seconds = Double(p.bestTimestamp ?? -1) * tb.doubleValue
        // Keyframes every 24 frames: 0, ~1.001, ~2.002 s → seeking to 1.5 s lands on ~1.0 s.
        XCTAssertEqual(seconds, 1.001, accuracy: 0.05)
    }

    func testMissingFileFailsToOpen() {
        XCTAssertThrowsError(try MediaFile(url: URL(fileURLWithPath: "/nonexistent.mkv"), useCustomIO: true))
    }
}
