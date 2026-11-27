import Foundation

/// Turns decoded multichannel PCM into stereo (Virtual Surround, Stereo downmix).
/// Used on one feeder queue only; keeps whatever state it needs between calls.
protocol AudioChannelProcessor: AnyObject {
    /// "Virtual Surround (HRTF)", "stereo downmix".
    var name: String { get }
    /// Interleaved samples in `speakers` order (more than two channels) → interleaved stereo
    /// (L, R) with the same number of frames.
    func process(_ interleaved: [Float], speakers: [Speaker], sampleRate: Int) -> [Float]
    /// Forget filter/reverb state (after a seek).
    func reset()
}

enum SurroundMix {
    /// LFE level in each ear / each stereo channel (−6 dB).
    static let lfeGain: Float = 0.5
    /// Headroom for summing several channels into two (−3 dB).
    static let masterGain: Float = 0.708

    /// Soft knee above 0.9 so loud scenes saturate gently instead of clipping hard.
    @inline(__always)
    static func softClip(_ x: Float) -> Float {
        let knee: Float = 0.9
        let a = abs(x)
        guard a > knee else { return x }
        let y = knee + (1 - knee) * Float(tanh(Double((a - knee) / (1 - knee))))
        return x < 0 ? -y : y
    }
}

/// ITU-R BS.775-style stereo downmix: front channels panned at constant power by their angle,
/// surrounds/rears to their side at −3 dB, heights −3 dB, LFE −6 dB to both.
final class StereoDownmixer: AudioChannelProcessor {
    let name = "stereo downmix"

    func reset() {}

    static func gains(for speaker: Speaker) -> (left: Float, right: Float) {
        if speaker.isLFE { return (SurroundMix.lfeGain, SurroundMix.lfeGain) }
        let azimuth = speaker.azimuth
        var g: (left: Float, right: Float)
        if abs(azimuth) >= 180 {
            g = (0.5, 0.5)
        } else if abs(azimuth) >= 90 {
            g = azimuth < 0 ? (0.7071, 0) : (0, 0.7071)
        } else {
            // −30° … +30° → hard left … hard right (wides beyond ±30° stay on their side).
            let p = (min(max(azimuth, -30), 30) + 30) / 60 * Double.pi / 2
            g = (Float(cos(p)), Float(sin(p)))
            if abs(g.left) < 1e-6 { g.left = 0 }
            if abs(g.right) < 1e-6 { g.right = 0 }
        }
        if speaker.elevation > 0 { g = (g.left * 0.7071, g.right * 0.7071) }
        return g
    }

    func process(_ interleaved: [Float], speakers: [Speaker], sampleRate: Int) -> [Float] {
        let channels = speakers.count
        guard channels > 0 else { return [] }
        let frames = interleaved.count / channels
        let gains = speakers.map(Self.gains)
        let gl = gains.map { $0.left * SurroundMix.masterGain }
        let gr = gains.map { $0.right * SurroundMix.masterGain }
        var out = [Float](repeating: 0, count: frames * 2)
        interleaved.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for f in 0..<frames {
                    var l: Float = 0, r: Float = 0
                    let base = f * channels
                    for c in 0..<channels {
                        let x = src[base + c]
                        l += x * gl[c]
                        r += x * gr[c]
                    }
                    dst[2 * f] = SurroundMix.softClip(l)
                    dst[2 * f + 1] = SurroundMix.softClip(r)
                }
            }
        }
        return out
    }
}
