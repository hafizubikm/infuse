import Foundation
import AVFoundation
import CoreMedia
import CFFmpeg

/// What the engine needs from either video path.
protocol VideoFeeding: AnyObject {
    var onPrerolled: ((Int) -> Void)? { get set }
    var onEndOfStream: ((Int, CMTime) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    /// Called when the description changes (e.g. once it is known whether decoding is in hardware).
    var onDescriptionChanged: ((String) -> Void)? { get set }
    var renderDescription: String { get }
    var displaySize: CGSize { get }
    /// The compressed-path format (nil for the FFmpeg-decoded path).
    var compressedFormat: VideoTrackFormat? { get }
    func start(generation: Int, displayFrom: CMTime)
    func stop()
}

extension CompressedVideoFeeder: VideoFeeding {
    var renderDescription: String { "\(format.renderDescription) · hardware decode" }
    var displaySize: CGSize { format.displaySize }
    var compressedFormat: VideoTrackFormat? { format }
}

/// Decodes video with FFmpeg (VideoToolbox-accelerated where possible) and enqueues the
/// decoded frames as image-buffer sample buffers on the same AVSampleBufferVideoRenderer.
final class DecodedVideoFeeder: VideoFeeding, @unchecked Sendable {
    let renderer: AVSampleBufferVideoRenderer
    let packets: PacketQueue
    private let decoder: VideoDecoder
    private let factory: PixelBufferFactory
    private let timing: StreamTimeConverter
    private let defaultFrameDuration: CMTime
    private let codecLabel: String
    let displaySize: CGSize
    private let queue = DispatchQueue(label: "Reel.DecodedVideoFeeder", qos: .userInitiated)

    private var generation = 0
    private var running = false
    private var displayFrom: CMTime = .zero
    private var ready: [CMSampleBuffer] = []
    private var enqueuedDisplayable = 0
    private var lastEnd: CMTime = .invalid
    private var drained = false
    private var reachedEnd = false
    private var lastPTS: CMTime = .invalid

    var onPrerolled: ((Int) -> Void)?
    var onEndOfStream: ((Int, CMTime) -> Void)?
    var onError: ((Error) -> Void)?
    var onDescriptionChanged: ((String) -> Void)?
    var compressedFormat: VideoTrackFormat? { nil }

    var renderDescription: String {
        let how: String
        switch decoder.usesHardware {
        case .some(true): how = "FFmpeg + VideoToolbox decode"
        case .some(false): how = "FFmpeg software decode"
        case .none: how = "FFmpeg decode"
        }
        return "\(codecLabel) · \(how)"
    }

    init(renderer: AVSampleBufferVideoRenderer, packets: PacketQueue, stream: UnsafeMutablePointer<AVStream>,
         details: VideoDetails, timing: StreamTimeConverter, label: String) throws {
        self.renderer = renderer
        self.packets = packets
        self.timing = timing
        codecLabel = label
        decoder = try VideoDecoder(stream: stream)
        factory = PixelBufferFactory(details: details)
        displaySize = VideoFormatFactory.displaySize(details)
        let fps = (details.frameRate ?? 0) > 1 ? details.frameRate! : 24
        defaultFrameDuration = CMTime(seconds: 1 / fps, preferredTimescale: 90000)
    }

    func start(generation: Int, displayFrom: CMTime) {
        queue.async { [self] in
            self.generation = generation
            self.displayFrom = displayFrom
            decoder.flush()
            ready.removeAll()
            enqueuedDisplayable = 0
            lastEnd = .invalid
            lastPTS = .invalid
            drained = false
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
            if !ready.isEmpty {
                let sb = ready.removeFirst()
                renderer.enqueue(sb)
                enqueuedDisplayable += 1
                if enqueuedDisplayable == 2 { onPrerolled?(generation) }
                if renderer.status == .failed {
                    running = false
                    renderer.stopRequestingMediaData()
                    onError?(renderer.error ?? VideoFormatError.coreMedia(-1))
                    return
                }
                continue
            }
            if reachedEnd { return }
            if let packet = packets.pop() {
                guard packet.generation == generation else { continue }
                let wasKnown = decoder.usesHardware != nil
                decoder.decode(packet) { frame in collect(frame) }
                if !wasKnown, decoder.usesHardware != nil { onDescriptionChanged?(renderDescription) }
                continue
            }
            if packets.isFinished {
                if !drained {
                    drained = true
                    decoder.decode(nil) { frame in collect(frame) }
                    continue
                }
                finish()
                return
            }
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

    private func collect(_ frame: UnsafeMutablePointer<AVFrame>) {
        let f = frame.pointee
        var pts: CMTime
        if f.best_effort_timestamp != ffNoPTS { pts = timing.time(f.best_effort_timestamp) }
        else if f.pts != ffNoPTS { pts = timing.time(f.pts) }
        else if lastPTS.isValid { pts = CMTimeAdd(lastPTS, defaultFrameDuration) }
        else { pts = displayFrom }
        // Guard against decoders repeating timestamps.
        if lastPTS.isValid, CMTimeCompare(pts, lastPTS) <= 0 { pts = CMTimeAdd(lastPTS, defaultFrameDuration) }
        lastPTS = pts
        let duration = f.duration > 0 ? timing.duration(f.duration) : defaultFrameDuration
        let end = CMTimeAdd(pts, duration)
        if CMTimeCompare(end, displayFrom) <= 0 { return }   // before the seek target
        if let sb = factory.sampleBuffer(for: frame, pts: pts, duration: duration) {
            ready.append(sb)
            if !lastEnd.isValid || CMTimeCompare(end, lastEnd) > 0 { lastEnd = end }
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
