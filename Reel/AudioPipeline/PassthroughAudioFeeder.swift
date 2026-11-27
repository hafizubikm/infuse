import Foundation
import AVFoundation
import CoreMedia
import CFFmpeg

/// Common interface of the audio feeders (passthrough now, FFmpeg-decoded PCM in milestone 4).
protocol AudioFeeding: AnyObject {
    /// Called on the feeder queue (with the generation) once ~0.3 s past the start point is
    /// enqueued, or the stream ended.
    var onPrerolled: ((Int) -> Void)? { get set }
    /// Called on the feeder queue after the last packet: (generation, end time of the audio).
    var onEndOfStream: ((Int, CMTime) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    var formatDescriptionText: String { get }
    func start(generation: Int, playFrom: CMTime)
    func stop()
}

/// Sends AAC / AC-3 / E-AC-3 packets to AVSampleBufferAudioRenderer untouched, so macOS decodes
/// them (including Dolby Atmos JOC) and spatializes them for AirPods.
final class PassthroughAudioFeeder: AudioFeeding, @unchecked Sendable {
    let renderer: AVSampleBufferAudioRenderer
    let packets: PacketQueue
    private let codecpar: AVCodecParameters
    private let timing: StreamTimeConverter
    private let queue = DispatchQueue(label: "Reel.AudioFeeder", qos: .userInitiated)

    private var format: PassthroughAudioFormat?
    private var generation = 0
    private var running = false
    private var playFrom: CMTime = .zero
    private var nextPTS: CMTime = .invalid
    private var prerolled = false
    private var reachedEnd = false

    var onPrerolled: ((Int) -> Void)?
    var onEndOfStream: ((Int, CMTime) -> Void)?
    var onError: ((Error) -> Void)?
    private(set) var formatDescriptionText = ""

    init(renderer: AVSampleBufferAudioRenderer, packets: PacketQueue, codecpar: AVCodecParameters,
         timing: StreamTimeConverter) {
        self.renderer = renderer
        self.packets = packets
        self.codecpar = codecpar
        self.timing = timing
    }

    func start(generation: Int, playFrom: CMTime) {
        queue.async { [self] in
            self.generation = generation
            self.playFrom = playFrom
            nextPTS = .invalid
            prerolled = false
            reachedEnd = false
            running = true
            arm()
        }
    }

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
            do {
                if format == nil {
                    format = try AudioFormatFactory.makePassthrough(par: codecpar, firstPacket: packet)
                    formatDescriptionText = format?.description ?? ""
                }
                if let sb = makeSampleBuffer(packet) { renderer.enqueue(sb) }
            } catch {
                running = false
                renderer.stopRequestingMediaData()
                onError?(error)
                return
            }
            if renderer.status == .failed {
                running = false
                renderer.stopRequestingMediaData()
                onError?(renderer.error ?? AudioFormatError.coreAudio(-1))
                return
            }
        }
    }

    private func finish() {
        guard !reachedEnd else { return }
        reachedEnd = true
        renderer.stopRequestingMediaData()
        if !prerolled { prerolled = true; onPrerolled?(generation) }
        onEndOfStream?(generation, nextPTS.isValid ? nextPTS : playFrom)
    }

    private func makeSampleBuffer(_ packet: Packet) -> CMSampleBuffer? {
        guard let format else { return nil }
        let packetDuration = CMTime(value: CMTimeValue(format.framesPerPacket), timescale: CMTimeScale(format.sampleRate))
        let pts: CMTime
        if let ts = packet.bestTimestamp { pts = timing.time(ts) }
        else if nextPTS.isValid { pts = nextPTS }
        else { return nil }
        let end = CMTimeAdd(pts, packetDuration)
        nextPTS = end

        // Entirely before the seek target → skip.
        if CMTimeCompare(end, playFrom) <= 0 { return nil }

        var bytes = packet.bytes
        if format.stripsADTSHeader, let header = AACConfig.parseADTS(bytes), header.headerLength < bytes.count {
            bytes = UnsafeRawBufferPointer(rebasing: bytes[header.headerLength...])
        }
        guard let block = SampleBufferFactory.blockBuffer(bytes) else { return nil }

        var desc = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                mDataByteSize: UInt32(bytes.count))
        var sb: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format.formatDescription,
            sampleCount: 1, presentationTimeStamp: pts, packetDescriptions: &desc, sampleBufferOut: &sb) == noErr,
              let sb
        else { return nil }

        // Trim the part before the seek target, and encoder priming/padding signalled by FFmpeg.
        var trimStart = CMTimeCompare(pts, playFrom) < 0 ? CMTimeSubtract(playFrom, pts) : .zero
        if let skip = packet.sideData(AV_PKT_DATA_SKIP_SAMPLES), skip.count >= 8 {
            let startSkip = skip.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
            let endSkip = skip.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
            let s = CMTime(value: CMTimeValue(startSkip), timescale: CMTimeScale(format.sampleRate))
            if CMTimeCompare(s, trimStart) > 0 { trimStart = s }
            if endSkip > 0 {
                let e = CMTime(value: CMTimeValue(endSkip), timescale: CMTimeScale(format.sampleRate))
                CMSetAttachment(sb, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd,
                                value: CMTimeCopyAsDictionary(e, allocator: kCFAllocatorDefault),
                                attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
            }
        }
        if CMTimeCompare(trimStart, .zero) > 0 {
            CMSetAttachment(sb, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                            value: CMTimeCopyAsDictionary(CMTimeMinimum(trimStart, packetDuration), allocator: kCFAllocatorDefault),
                            attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
        }

        if !prerolled, CMTimeCompare(end, CMTimeAdd(playFrom, CMTime(value: 3, timescale: 10))) >= 0 {
            prerolled = true
            onPrerolled?(generation)
        }
        return sb
    }
}
