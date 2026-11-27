import Foundation
import AVFoundation

/// Virtual Surround for headphones that aren't AirPods/Beats.
///
/// Every channel becomes a virtual loudspeaker around the listener — C 0°, L/R ±30°,
/// Ls/Rs ±110°, Lrs/Rrs ±150°, heights raised 45° — rendered binaurally with Apple's
/// high-quality HRTF (`AVAudioEnvironmentNode`, `.HRTFHQ`) in an offline, manual-rendering
/// `AVAudioEngine`. LFE is mixed into both ears. The output is stereo at the source rate with
/// exactly as many frames as the input, so it slots into the PCM feeder's timeline (and the
/// audio-master clock) unchanged.
final class BinauralVirtualizer: AudioChannelProcessor {
    static let maxFrames: AVAudioFrameCount = 4096
    /// Distance of the virtual speakers (the attenuation reference distance, so gain is 1).
    static let speakerDistance: Float = 1

    let roomAmbience: Bool
    var name: String { roomAmbience ? "Virtual Surround (HRTF, room)" : "Virtual Surround (HRTF)" }

    private var engine: AVAudioEngine?
    private var output: AVAudioPCMBuffer?
    private let input = ChannelInput()
    private var configuredSpeakers: [Speaker] = []
    private var configuredRate = 0
    private var needsReset = false
    /// Set if the engine can't be built or fails; the plain downmix is used instead.
    private(set) var failed = false
    private lazy var fallback = StereoDownmixer()

    init(roomAmbience: Bool = false) {
        self.roomAmbience = roomAmbience
    }

    deinit {
        engine?.stop()
    }

    func reset() {
        needsReset = true
    }

    func process(_ interleaved: [Float], speakers: [Speaker], sampleRate: Int) -> [Float] {
        let channels = speakers.count
        guard channels > 0, sampleRate > 0 else { return [] }
        let frames = interleaved.count / channels
        guard frames > 0 else { return [] }
        if failed { return fallback.process(interleaved, speakers: speakers, sampleRate: sampleRate) }
        if engine == nil || speakers != configuredSpeakers || sampleRate != configuredRate {
            do {
                try configure(speakers: speakers, sampleRate: sampleRate)
            } catch {
                return giveUp(error, interleaved, speakers, sampleRate)
            }
        } else if needsReset, let engine {
            engine.stop()
            engine.reset()
            do { try engine.start() } catch { return giveUp(error, interleaved, speakers, sampleRate) }
        }
        needsReset = false
        guard let engine, let output else { return fallback.process(interleaved, speakers: speakers, sampleRate: sampleRate) }

        var result = [Float](repeating: 0, count: frames * 2)
        var offset = 0
        while offset < frames {
            let n = min(Int(Self.maxFrames), frames - offset)
            input.load(interleaved, channels: channels, firstFrame: offset, frames: n)
            do {
                let status = try engine.renderOffline(AVAudioFrameCount(n), to: output)
                guard status == .success, Int(output.frameLength) == n, let data = output.floatChannelData else {
                    throw VirtualizerError.render(status.rawValue)
                }
                let left = data[0], right = data[1]
                result.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<n {
                        dst[2 * (offset + i)] = SurroundMix.softClip(left[i])
                        dst[2 * (offset + i) + 1] = SurroundMix.softClip(right[i])
                    }
                }
            } catch {
                return giveUp(error, interleaved, speakers, sampleRate)
            }
            offset += n
        }
        return result
    }

    private func giveUp(_ error: Error, _ interleaved: [Float], _ speakers: [Speaker], _ rate: Int) -> [Float] {
        Log.audio.error("Virtual Surround unavailable (\(String(describing: error), privacy: .public)); using a stereo downmix")
        failed = true
        engine?.stop()
        engine = nil
        return fallback.process(interleaved, speakers: speakers, sampleRate: rate)
    }

    enum VirtualizerError: Error, CustomStringConvertible {
        case format
        case render(Int)
        var description: String {
            switch self {
            case .format: return "unsupported format"
            case .render(let s): return "offline render failed (\(s))"
            }
        }
    }

    /// Position of a speaker for the environment node (listener at the origin facing −Z,
    /// +X to the right, +Y up).
    static func position(for speaker: Speaker) -> AVAudio3DPoint {
        let az = speaker.azimuth * .pi / 180
        let el = speaker.elevation * .pi / 180
        let d = Double(speakerDistance)
        return AVAudio3DPoint(x: Float(sin(az) * cos(el) * d), y: Float(sin(el) * d), z: Float(-cos(az) * cos(el) * d))
    }

    private func configure(speakers: [Speaker], sampleRate: Int) throws {
        engine?.stop()
        engine = nil
        let rate = Double(sampleRate)
        guard let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
            throw VirtualizerError.format
        }
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: Self.maxFrames)

        let environment = AVAudioEnvironmentNode()
        engine.attach(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: stereo)
        environment.outputType = .headphones
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
        let attenuation = environment.distanceAttenuationParameters
        attenuation.distanceAttenuationModel = .inverse
        attenuation.referenceDistance = Self.speakerDistance
        attenuation.maximumDistance = 100
        attenuation.rolloffFactor = 1
        environment.reverbParameters.enable = roomAmbience
        if roomAmbience {
            environment.reverbParameters.loadFactoryReverbPreset(.mediumRoom)
            environment.reverbParameters.level = -8
        }

        input.prepare(channels: speakers.count, capacity: Int(Self.maxFrames))
        for (channel, speaker) in speakers.enumerated() {
            let source = AVAudioSourceNode(format: mono) { [input] _, _, frameCount, bufferList -> OSStatus in
                let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
                guard let data = buffers.first?.mData else { return noErr }
                input.read(channel: channel, into: data.assumingMemoryBound(to: Float.self), frames: Int(frameCount))
                return noErr
            }
            engine.attach(source)
            engine.connect(source, to: environment, format: mono)
            source.renderingAlgorithm = .HRTFHQ
            source.position = Self.position(for: speaker)
            source.volume = speaker.isLFE ? SurroundMix.lfeGain : 1
            source.reverbBlend = roomAmbience && !speaker.isLFE ? 0.15 : 0
            source.obstruction = 0
            source.occlusion = 0
        }
        engine.mainMixerNode.outputVolume = SurroundMix.masterGain
        engine.prepare()
        try engine.start()
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: Self.maxFrames),
              engine.manualRenderingFormat.channelCount == 2 else {
            throw VirtualizerError.format
        }
        self.engine = engine
        output = buffer
        configuredSpeakers = speakers
        configuredRate = sampleRate
        Log.audio.notice("Virtual Surround: \(speakers.count) virtual speakers at \(sampleRate) Hz, HRTFHQ\(self.roomAmbience ? " + room" : "", privacy: .public)")
    }
}

/// Deinterleaved input for one render cycle, read by the per-channel source nodes. Accessed only
/// from the thread that calls `renderOffline` (offline rendering pulls synchronously).
private final class ChannelInput {
    private var channels: [UnsafeMutablePointer<Float>] = []
    private var cursors: [Int] = []
    private var available = 0
    private var capacity = 0

    deinit { free() }

    func prepare(channels count: Int, capacity: Int) {
        free()
        self.capacity = capacity
        channels = (0..<count).map { _ in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            p.initialize(repeating: 0, count: capacity)
            return p
        }
        cursors = Array(repeating: 0, count: count)
        available = 0
    }

    func load(_ interleaved: [Float], channels count: Int, firstFrame: Int, frames: Int) {
        precondition(count == channels.count && frames <= capacity)
        interleaved.withUnsafeBufferPointer { src in
            for c in 0..<count {
                let dst = channels[c]
                var i = firstFrame * count + c
                for f in 0..<frames {
                    dst[f] = src[i]
                    i += count
                }
            }
        }
        available = frames
        for c in 0..<cursors.count { cursors[c] = 0 }
    }

    func read(channel: Int, into dst: UnsafeMutablePointer<Float>, frames: Int) {
        guard channel < channels.count else {
            dst.initialize(repeating: 0, count: frames)
            return
        }
        let start = cursors[channel]
        let n = max(0, min(frames, available - start))
        if n > 0 { dst.update(from: channels[channel] + start, count: n) }
        if n < frames { (dst + n).initialize(repeating: 0, count: frames - n) }
        cursors[channel] = start + frames
    }

    private func free() {
        channels.forEach { $0.deallocate() }
        channels = []
        cursors = []
    }
}
