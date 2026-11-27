import XCTest
import AVFoundation
@testable import Reel

/// Renders a burst on one channel at a time through the HRTF virtualizer and checks that it
/// arrives at the expected ear.
final class VirtualizerTests: XCTestCase {
    let rate = 48000
    let layout51: [Speaker] = [.frontLeft, .frontRight, .center, .lfe, .surroundLeft, .surroundRight]
    let layout71: [Speaker] = [.frontLeft, .frontRight, .center, .lfe, .surroundLeft, .surroundRight, .rearLeft, .rearRight]

    /// Pseudo-random noise burst (or a 60 Hz tone for LFE) on `channel`, silence elsewhere.
    private func burst(_ speakers: [Speaker], channel: Int, frames: Int = 9600, start: Int = 480, length: Int = 2400) -> [Float] {
        var out = [Float](repeating: 0, count: frames * speakers.count)
        var seed: UInt32 = 12345
        for f in start..<min(frames, start + length) {
            let x: Float
            if speakers[channel].isLFE {
                x = 0.5 * Float(sin(2 * Double.pi * 60 * Double(f) / Double(rate)))
            } else {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                x = (Float(seed >> 8) / Float(1 << 24) - 0.5)
            }
            out[f * speakers.count + channel] = x
        }
        return out
    }

    private func rms(_ stereo: [Float], ear: Int) -> Float {
        var sum: Float = 0
        var i = ear
        while i < stereo.count { sum += stereo[i] * stereo[i]; i += 2 }
        return (sum / Float(stereo.count / 2)).squareRoot()
    }

    private func db(_ a: Float, _ b: Float) -> Float { 20 * log10(max(a, 1e-9) / max(b, 1e-9)) }

    func testEachChannelReachesTheExpectedEar() {
        for layout in [layout51, layout71] {
            let v = BinauralVirtualizer()
            for (channel, speaker) in layout.enumerated() {
                let input = burst(layout, channel: channel)
                let out = v.process(input, speakers: layout, sampleRate: rate)
                XCTAssertFalse(v.failed, "the offline HRTF engine should run")
                XCTAssertEqual(out.count, input.count / layout.count * 2)
                XCTAssertTrue(out.allSatisfy(\.isFinite))
                let l = rms(out, ear: 0), r = rms(out, ear: 1)
                let ild = db(l, r)
                print(String(format: "virtualizer %dch %@: L %.4f R %.4f (L−R %.1f dB)", layout.count, speaker.rawValue, l, r, ild))
                XCTAssertGreaterThan(max(l, r), 0.005, "\(speaker) is audible")
                switch speaker {
                case .frontLeft, .surroundLeft, .rearLeft:
                    XCTAssertGreaterThan(ild, 3, "\(speaker) should be louder in the left ear")
                case .frontRight, .surroundRight, .rearRight:
                    XCTAssertLessThan(ild, -3, "\(speaker) should be louder in the right ear")
                default:
                    XCTAssertLessThan(abs(ild), 2, "\(speaker) should be centred")
                }
                v.reset()
            }
        }
    }

    /// The virtual speakers aren't just panned: the surround's ILD is larger than the front's,
    /// and front/back at the same side sound different (spectral HRTF cues).
    func testSurroundsDifferFromFronts() {
        let v = BinauralVirtualizer()
        let front = v.process(burst(layout71, channel: 0), speakers: layout71, sampleRate: rate)
        v.reset()
        let rear = v.process(burst(layout71, channel: 6), speakers: layout71, sampleRate: rate)
        var diff: Float = 0, energy: Float = 0
        for i in 0..<front.count { diff += (front[i] - rear[i]) * (front[i] - rear[i]); energy += front[i] * front[i] }
        XCTAssertGreaterThan(diff / max(energy, 1e-9), 0.1, "front-left and rear-left render differently")
    }

    func testLatencyAndLongBuffers() {
        let v = BinauralVirtualizer()
        let frames = 10_000                 // more than one render slice
        var input = [Float](repeating: 0, count: frames * 6)
        input[1000 * 6 + 2] = 1             // centre impulse at frame 1000
        let out = v.process(input, speakers: layout51, sampleRate: rate)
        XCTAssertEqual(out.count, frames * 2)
        var peak = 0
        for f in 0..<frames where abs(out[2 * f]) > abs(out[2 * peak]) { peak = f }
        let delay = peak - 1000
        print("virtualizer latency: \(delay) frames (\(String(format: "%.2f", Double(delay) / Double(rate) * 1000)) ms)")
        XCTAssertGreaterThanOrEqual(delay, 0)
        XCTAssertLessThan(delay, rate / 50, "under 20 ms, so lip-sync is unaffected")
    }

    func testRoomAmbienceAndFormatChanges() {
        let v = BinauralVirtualizer(roomAmbience: true)
        let out51 = v.process(burst(layout51, channel: 2), speakers: layout51, sampleRate: rate)
        XCTAssertTrue(out51.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(rms(out51, ear: 0), 0.005)
        // Layout and rate change mid-stream (e.g. a different track) rebuild the engine.
        let out71 = v.process(burst(layout71, channel: 4, frames: 4410), speakers: layout71, sampleRate: 44100)
        XCTAssertEqual(out71.count, 4410 * 2)
        XCTAssertFalse(v.failed)
    }

    func testDownmixFallbackMatchesShape() {
        // The plain downmix is what Stereo mode uses; same contract as the virtualizer.
        let input = burst(layout71, channel: 4)
        let out = StereoDownmixer().process(input, speakers: layout71, sampleRate: rate)
        XCTAssertEqual(out.count, input.count / 8 * 2)
        XCTAssertGreaterThan(rms(out, ear: 0), 0.01)
        XCTAssertEqual(rms(out, ear: 1), 0)
    }
}
