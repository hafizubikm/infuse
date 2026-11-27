import XCTest
import CFFmpeg
@testable import Reel

/// Decodes the multichannel fixtures with FFmpeg and checks every channel ends up where it
/// belongs: each source channel i carries a sine at 220 + 110·i Hz (see make-fixtures.sh).
final class AudioDecoderTests: XCTestCase {
    private struct Decoded {
        var speakers: [Speaker] = []
        var sampleRate = 0
        var samples: [Float] = []
        var firstPTS: Int64?
    }

    private func decode(_ name: String, seconds: Double = 1.0) throws -> Decoded {
        let file = try MediaFile(url: try TestMedia.url(name))
        let audio = try XCTUnwrap(file.info.primaryAudio)
        let st = try XCTUnwrap(file.stream(at: audio.index))
        let decoder = try AudioDecoder(stream: st)
        var out = Decoded()
        let raw = try XCTUnwrap(av_packet_alloc())
        var rawOpt: UnsafeMutablePointer<AVPacket>? = raw
        defer { av_packet_free(&rawOpt) }
        while av_read_frame(file.formatContext, raw) >= 0 {
            guard Int(raw.pointee.stream_index) == audio.index, let p = Packet(moving: raw, generation: 0) else {
                av_packet_unref(raw); continue
            }
            for o in decoder.decode(p) {
                if out.speakers.isEmpty { out.speakers = o.speakers; out.sampleRate = o.sampleRate; out.firstPTS = o.pts }
                out.samples += o.samples
            }
            if out.sampleRate > 0, out.samples.count / max(1, out.speakers.count) >= Int(Double(out.sampleRate) * seconds) { break }
        }
        return out
    }

    /// Goertzel power of `frequency` in channel `channel` (skipping the first 0.1 s of codec delay).
    private func power(_ d: Decoded, channel: Int, frequency: Double) -> Double {
        let n = d.speakers.count
        let frames = d.samples.count / n
        let start = min(frames / 4, d.sampleRate / 10)
        let k = 2 * cos(2 * Double.pi * frequency / Double(d.sampleRate))
        var s1 = 0.0, s2 = 0.0
        for i in start..<frames {
            let s0 = Double(d.samples[i * n + channel]) + k * s1 - s2
            s2 = s1; s1 = s0
        }
        return s1 * s1 + s2 * s2 - k * s1 * s2
    }

    /// Asserts each speaker's strongest tone among all source tones is the expected one.
    private func assertTones(_ d: Decoded, expected: [Speaker: Double], skipLFE: Bool = false,
                             file: StaticString = #filePath, line: UInt = #line) {
        let candidates = Set(expected.values).sorted()
        for (index, speaker) in d.speakers.enumerated() {
            guard let want = expected[speaker] else {
                XCTFail("unexpected speaker \(speaker)", file: file, line: line); continue
            }
            if skipLFE && speaker.isLFE { continue }
            let best = candidates.max { power(d, channel: index, frequency: $0) < power(d, channel: index, frequency: $1) }
            XCTAssertEqual(best, want, "\(speaker) carries the wrong tone", file: file, line: line)
        }
    }

    private let tones51: [Speaker: Double] = [.frontLeft: 220, .frontRight: 330, .center: 440, .lfe: 550,
                                              .surroundLeft: 660, .surroundRight: 770]

    func testFLAC71ChannelOrder() throws {
        let d = try decode("h264_flac71.mkv")
        XCTAssertEqual(d.speakers, [.frontLeft, .frontRight, .center, .lfe, .rearLeft, .rearRight, .surroundLeft, .surroundRight])
        XCTAssertEqual(d.sampleRate, 48000)
        // FFmpeg 7.1 order FL FR FC LFE BL BR SL SR: rears carry 660/770, sides 880/990.
        assertTones(d, expected: [.frontLeft: 220, .frontRight: 330, .center: 440, .lfe: 550,
                                  .rearLeft: 660, .rearRight: 770, .surroundLeft: 880, .surroundRight: 990])
    }

    func testTrueHD51() throws {
        let d = try decode("h264_truehd51.mkv")
        XCTAssertEqual(d.speakers.count, 6)
        assertTones(d, expected: tones51)
    }

    func testDTS51() throws {
        let d = try decode("h264_dts51.mkv")
        XCTAssertEqual(d.speakers.count, 6)
        assertTones(d, expected: tones51, skipLFE: true)   // the DTS LFE channel is band-limited
    }

    func testOpus51() throws {
        let d = try decode("av1_opus.mkv")
        XCTAssertEqual(d.speakers.count, 6)
        assertTones(d, expected: tones51, skipLFE: true)
    }

    func testPCMWithoutStoredLayoutDefaultsTo51() throws {
        // Matroska stores only a channel count for PCM; FFmpeg's default 6-channel order is 5.1.
        let d = try decode("h264_pcm51.mkv")
        XCTAssertEqual(d.speakers, [.frontLeft, .frontRight, .center, .lfe, .surroundLeft, .surroundRight])
        assertTones(d, expected: tones51)
    }

    func testStereoMP3AndMP2() throws {
        for name in ["mpeg4_mp3.avi", "mpeg2_mp2.ts"] {
            let d = try decode(name)
            XCTAssertEqual(d.speakers, [.frontLeft, .frontRight], name)
            assertTones(d, expected: [.frontLeft: 220, .frontRight: 330])
        }
    }

    func testSpeakerRolesFor51Variants() {
        var back = AVChannelLayout(), side = AVChannelLayout()
        XCTAssertEqual(av_channel_layout_from_string(&back, "5.1"), 0)
        XCTAssertEqual(av_channel_layout_from_string(&side, "5.1(side)"), 0)
        let expected: [Speaker] = [.frontLeft, .frontRight, .center, .lfe, .surroundLeft, .surroundRight]
        XCTAssertEqual(SpeakerLayout.speakers(for: back), expected)
        XCTAssertEqual(SpeakerLayout.speakers(for: side), expected)
    }
}
