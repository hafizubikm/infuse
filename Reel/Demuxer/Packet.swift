import Foundation
import CFFmpeg

/// An owned AVPacket plus the seek generation it was read in.
final class Packet: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<AVPacket>
    /// Incremented by the demuxer on every seek; consumers drop packets from older generations.
    let generation: Int

    /// Takes over the contents of `source` (which is left blank, ready for reuse).
    init?(moving source: UnsafeMutablePointer<AVPacket>, generation: Int) {
        guard let p = av_packet_alloc() else { return nil }
        av_packet_move_ref(p, source)
        pointer = p
        self.generation = generation
    }

    deinit {
        var p: UnsafeMutablePointer<AVPacket>? = pointer
        av_packet_free(&p)
    }

    var streamIndex: Int { Int(pointer.pointee.stream_index) }
    var pts: Int64? { pointer.pointee.pts == ffNoPTS ? nil : pointer.pointee.pts }
    var dts: Int64? { pointer.pointee.dts == ffNoPTS ? nil : pointer.pointee.dts }
    /// Duration in stream time-base units (0 if unknown).
    var duration: Int64 { pointer.pointee.duration }
    var isKeyframe: Bool { pointer.pointee.flags & AV_PKT_FLAG_KEY != 0 }
    var isCorrupt: Bool { pointer.pointee.flags & AV_PKT_FLAG_CORRUPT != 0 }
    var size: Int { Int(pointer.pointee.size) }

    /// The packet payload. Valid while the packet is alive.
    var bytes: UnsafeRawBufferPointer {
        guard let data = pointer.pointee.data, pointer.pointee.size > 0 else {
            return UnsafeRawBufferPointer(start: nil, count: 0)
        }
        return UnsafeRawBufferPointer(start: data, count: Int(pointer.pointee.size))
    }

    /// Presentation timestamp, falling back to the decode timestamp.
    var bestTimestamp: Int64? { pts ?? dts }

    func sideData(_ type: AVPacketSideDataType) -> UnsafeRawBufferPointer? {
        var size: Int = 0
        guard let data = av_packet_get_side_data(pointer, type, &size), size > 0 else { return nil }
        return UnsafeRawBufferPointer(start: data, count: size)
    }
}
