import Foundation
import AVFoundation
import CoreMedia
import CFFmpeg

/// Decodes audio with FFmpeg (TrueHD, DTS, FLAC, Opus, PCM …) and feeds interleaved Float32
/// PCM with a proper channel layout to AVSampleBufferAudioRenderer, which spatializes
/// multichannel PCM for AirPods just like natively decoded audio.
final class PCMAudioFeeder: AudioFeeding, @unchecked Sendable {
    /// Frames per sample buffer (TrueHD frames are only 40 samples, so they are batched).
    static let chunkFrames = 4096

    let renderer: AVSampleBufferAudioRenderer
    let packets: PacketQueue
    private let decoder: AudioDecoder
    private let timing: StreamTimeConverter
    private let codecLabel: String
    private let queue = DispatchQueue(label: "Reel.PCMAudioFeeder", qos: .userInitiated)

    // Feeder-queue state
    private var generation = 0
    private var running = false
    private var playFrom: CMTime = .zero
    private var prerolled = false
    private var reachedEnd = false
    private var drained = false
    private var nextExpected: CMTime = .invalid

    private var pending: [Float] = []
    private var pendingStart: CMTime = .invalid
    private var pendingRate = 0
    private var pendingSpeakers: [Speaker] = []
    private var ready: [CMSampleBuffer] = []
    private var enqueuedEnd: CMTime = .invalid

    private var formatKey: (rate: Int, speakers: [Speaker])?
    private var formatDescription: CMAudioFormatDescription?
    private var plan: ChannelLayoutPlan?

    var onPrerolled: ((Int) -> Void)?
    var onEndOfStream: ((Int, CMTime) -> Void)?
    var onError: ((Error) -> Void)?
    private(set) var formatDescriptionText = ""

    init(renderer: AVSampleBufferAudioRenderer, packets: PacketQueue, stream: UnsafeMutablePointer<AVStream>,
         timing: StreamTimeConverter, label: String) throws {
        self.renderer = renderer
        self.packets = packets
        self.timing = timing
        codecLabel = label
        decoder = try AudioDecoder(stream: stream)
    }

    func start(generation: Int, playFrom: CMTime) {
        queue.async { [self] in
            self.generation = generation
            self.playFrom = playFrom
            decoder.flush()
            pending.removeAll(keepingCapacity: true)
            pendingStart = .invalid
            ready.removeAll()
            nextExpected = .invalid
            enqueuedEnd = .invalid
            prerolled = false
            reachedEnd = false
            drained = false
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
            if !ready.isEmpty {
                let sb = ready.removeFirst()
                renderer.enqueue(sb)
                let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sb), CMSampleBufferGetDuration(sb))
                enqueuedEnd = end
                if !prerolled, CMTimeCompare(end, CMTimeAdd(playFrom, CMTime(value: 3, timescale: 10))) >= 0 {
                    prerolled = true
                    onPrerolled?(generation)
                }
                if renderer.status == .failed {
                    running = false
                    renderer.stopRequestingMediaData()
                    onError?(renderer.error ?? AudioFormatError.coreAudio(-1))
                    return
                }
                continue
            }
            if reachedEnd { return }
            if let packet = packets.pop() {
                guard packet.generation == generation else { continue }
                for output in decoder.decode(packet) { append(output) }
                if pendingFrames >= Self.chunkFrames { emitPending() }
                continue
            }
            if packets.isFinished {
                if !drained {
                    drained = true
                    for output in decoder.decode(nil) { append(output) }
                    emitPending()
                    continue
                }
                finish()
                return
            }
            // Wait for the demuxer.
            renderer.stopRequestingMediaData()
            let gen = generation
            packets.whenAvailable { [weak self] in
                self?.queue.async {
                    guard let self, self.running, self.generation == gen else { return }
                    self.arm()
                }
            }
            return
        }
    }

    private var pendingFrames: Int { pendingSpeakers.isEmpty ? 0 : pending.count / pendingSpeakers.count }

    private func append(_ output: AudioDecoder.Output) {
        let channels = output.speakers.count
        guard channels > 0, output.frameCount > 0, output.sampleRate > 0 else { return }
        let rate = CMTimeScale(output.sampleRate)
        var start = output.pts.map { timing.time($0) } ?? nextExpected
        if !start.isValid { start = playFrom }
        // Keep buffers contiguous unless the stream really jumps (> 40 ms).
        if nextExpected.isValid, abs(CMTimeGetSeconds(CMTimeSubtract(start, nextExpected))) < 0.04 {
            start = nextExpected
        }
        let duration = CMTime(value: CMTimeValue(output.frameCount), timescale: rate)
        let end = CMTimeAdd(start, duration)
        nextExpected = end
        if CMTimeCompare(end, playFrom) <= 0 { return }   // entirely before the seek target

        var samples = output.samples
        var first = start
        if CMTimeCompare(start, playFrom) < 0 {             // trim up to the seek target, sample-exact
            let skip = min(output.frameCount, Int((CMTimeGetSeconds(CMTimeSubtract(playFrom, start)) * Double(rate)).rounded()))
            samples.removeFirst(skip * channels)
            first = CMTimeAdd(start, CMTime(value: CMTimeValue(skip), timescale: rate))
        }

        let contiguous = pendingStart.isValid && output.sampleRate == pendingRate && output.speakers == pendingSpeakers
            && abs(CMTimeGetSeconds(CMTimeSubtract(first, pendingEnd))) < 0.001
        if !contiguous { emitPending() }
        if pending.isEmpty {
            pendingStart = first
            pendingRate = output.sampleRate
            pendingSpeakers = output.speakers
        }
        pending.append(contentsOf: samples)
    }

    private var pendingEnd: CMTime {
        guard pendingStart.isValid, pendingRate > 0 else { return .invalid }
        return CMTimeAdd(pendingStart, CMTime(value: CMTimeValue(pendingFrames), timescale: CMTimeScale(pendingRate)))
    }

    private func emitPending() {
        guard !pending.isEmpty, pendingStart.isValid else { return }
        do {
            if formatKey == nil || formatKey!.rate != pendingRate || formatKey!.speakers != pendingSpeakers {
                let p = ChannelLayoutMapper.plan(for: pendingSpeakers)
                plan = p
                formatDescription = try ChannelLayoutMapper.pcmFormatDescription(sampleRate: pendingRate, plan: p)
                formatKey = (pendingRate, pendingSpeakers)
                formatDescriptionText = "\(codecLabel) → \(p.name) Float32 PCM \(pendingRate / 1000) kHz"
            }
            guard let fd = formatDescription, let plan else { return }
            let data = plan.reorder(pending)
            let frames = data.count / plan.channelCount
            guard let block = data.withUnsafeBytes({ SampleBufferFactory.blockBuffer($0) }) else { return }
            var sb: CMSampleBuffer?
            let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fd,
                sampleCount: frames, presentationTimeStamp: pendingStart, packetDescriptions: nil, sampleBufferOut: &sb)
            if status == noErr, let sb { ready.append(sb) }
        } catch {
            onError?(error)
        }
        pending.removeAll(keepingCapacity: true)
        pendingStart = .invalid
    }

    private func finish() {
        guard !reachedEnd else { return }
        reachedEnd = true
        renderer.stopRequestingMediaData()
        if !prerolled { prerolled = true; onPrerolled?(generation) }
        onEndOfStream?(generation, enqueuedEnd.isValid ? enqueuedEnd : playFrom)
    }
}
