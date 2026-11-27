import Foundation
import AVFoundation
import CoreMedia
import CFFmpeg

/// Turns compressed video packets into CMSampleBuffers for VideoToolbox: timestamps in media
/// time, NAL rewriting (Annex-B → length-prefixed, dropped NAL types), sync flags.
struct VideoSampleBuilder {
    let format: VideoTrackFormat
    let timing: StreamTimeConverter
    let defaultFrameDuration: CMTime
    /// Matroska has no decode timestamps; then the decoder works in enqueue order.
    let useDecodeTimestamps: Bool

    init(format: VideoTrackFormat, timing: StreamTimeConverter, frameRate: Double?, isMatroska: Bool) {
        self.format = format
        self.timing = timing
        let fps = (frameRate ?? 0) > 1 ? frameRate! : 24
        defaultFrameDuration = CMTime(seconds: 1 / fps, preferredTimescale: 90000)
        useDecodeTimestamps = !isMatroska
    }

    struct Sample {
        let buffer: CMSampleBuffer
        let pts: CMTime
        let end: CMTime
        let displayable: Bool
    }

    /// - Parameter displayFrom: frames ending at or before this time get DoNotDisplay.
    func makeSample(_ packet: Packet, displayFrom: CMTime) -> Sample? {
        guard let ts = packet.bestTimestamp else { return nil }
        let pts = timing.time(ts)
        let duration = packet.duration > 0 ? timing.duration(packet.duration) : defaultFrameDuration
        var dts = CMTime.invalid
        if useDecodeTimestamps, let d = packet.dts { dts = timing.time(d) }
        guard let block = payload(packet) else { return nil }

        var timingInfo = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: dts)
        var size = CMBlockBufferGetDataLength(block)
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format.formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr, let sb
        else { return nil }

        if !packet.isKeyframe {
            SampleBufferFactory.setSampleAttachment(sb, kCMSampleAttachmentKey_NotSync, true)
        }
        let end = CMTimeAdd(pts, duration.isValid ? duration : defaultFrameDuration)
        let displayable = CMTimeCompare(end, displayFrom) > 0
        if !displayable {
            SampleBufferFactory.setSampleAttachment(sb, kCMSampleAttachmentKey_DoNotDisplay, true)
        }
        return Sample(buffer: sb, pts: pts, end: end, displayable: displayable)
    }

    private func payload(_ packet: Packet) -> CMBlockBuffer? {
        let raw = packet.bytes
        let dropped = format.droppedNALTypes
        switch format.packetFormat {
        case .annexB:
            let codec = format.codec ?? .h264
            let aud = codec == .h264 ? NALUtils.h264AUD : NALUtils.hevcAUD
            return SampleBufferFactory.blockBuffer(
                NALUtils.annexBToLengthPrefixed(raw, codec: codec) { $0 == aud || dropped.contains($0) })
        case .lengthPrefixed(let lengthSize):
            // VideoToolbox reads the NAL length size from avcC/hvcC, so only rewrite (always with
            // 4-byte lengths) when NAL units must be dropped and the record already says 4.
            if !dropped.isEmpty, lengthSize == 4,
               let filtered = NALUtils.filterLengthPrefixed(raw, lengthSize: 4, codec: format.codec ?? .hevc,
                                                            drop: { dropped.contains($0) }) {
                return SampleBufferFactory.blockBuffer(filtered)
            }
            return SampleBufferFactory.blockBuffer(raw)
        case .av1:
            return SampleBufferFactory.blockBuffer(raw)
        }
    }
}

/// Pulls compressed video packets from a `PacketQueue` and enqueues them on an
/// AVSampleBufferVideoRenderer, which decodes them in hardware (VideoToolbox) and presents
/// them in sync with the render synchronizer.
final class CompressedVideoFeeder: @unchecked Sendable {
    let renderer: AVSampleBufferVideoRenderer
    let packets: PacketQueue
    let builder: VideoSampleBuilder
    var format: VideoTrackFormat { builder.format }
    private let queue = DispatchQueue(label: "Reel.VideoFeeder", qos: .userInitiated)

    // State below is only touched on `queue`.
    private var generation = 0
    private var running = false
    private var displayFrom: CMTime = .zero
    private var enqueuedDisplayable = 0
    private var lastEnd: CMTime = .invalid
    private var reachedEnd = false

    /// Called on the feeder queue (with the generation) when ≥ 2 displayable frames are enqueued
    /// after a (re)start, or the stream ended.
    var onPrerolled: ((Int) -> Void)?
    /// Called on the feeder queue when the last packet was enqueued: (generation, end time).
    var onEndOfStream: ((Int, CMTime) -> Void)?
    var onError: ((Error) -> Void)?

    init(renderer: AVSampleBufferVideoRenderer, packets: PacketQueue, builder: VideoSampleBuilder) {
        self.renderer = renderer
        self.packets = packets
        self.builder = builder
    }

    /// Starts (or restarts after a seek) feeding packets of `generation`; frames that end before
    /// `displayFrom` are decoded but not displayed.
    func start(generation: Int, displayFrom: CMTime) {
        queue.async { [self] in
            self.generation = generation
            self.displayFrom = displayFrom
            enqueuedDisplayable = 0
            lastEnd = .invalid
            reachedEnd = false
            running = true
            arm()
        }
    }

    /// Stops feeding (packets stay queued). Call before flushing the renderer.
    func stop() {
        queue.sync {
            running = false
            renderer.stopRequestingMediaData()
        }
    }

    private func arm() {
        guard running else { return }
        renderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.feed() }
    }

    private func feed() {
        guard running else { return }
        while renderer.isReadyForMoreMediaData {
            guard let packet = packets.pop() else {
                if packets.isFinished {
                    finish()
                } else {
                    // Nothing buffered yet: stop polling and re-arm when the demuxer delivers.
                    renderer.stopRequestingMediaData()
                    let gen = generation
                    packets.whenAvailable { [weak self] in
                        self?.queue.async {
                            guard let self, self.running, self.generation == gen else { return }
                            self.arm()
                        }
                    }
                }
                return
            }
            guard packet.generation == generation else { continue }
            if let sample = builder.makeSample(packet, displayFrom: displayFrom) {
                renderer.enqueue(sample.buffer)
                if !lastEnd.isValid || CMTimeCompare(sample.end, lastEnd) > 0 { lastEnd = sample.end }
                if sample.displayable {
                    enqueuedDisplayable += 1
                    if enqueuedDisplayable == 2 { onPrerolled?(generation) }
                }
            }
            if renderer.status == .failed {
                running = false
                renderer.stopRequestingMediaData()
                onError?(renderer.error ?? VideoFormatError.coreMedia(-1))
                return
            }
        }
    }

    private func finish() {
        guard !reachedEnd else { return }
        reachedEnd = true
        renderer.stopRequestingMediaData()
        if enqueuedDisplayable < 2 { onPrerolled?(generation) }
        onEndOfStream?(generation, lastEnd.isValid ? lastEnd : displayFrom)
    }
}
