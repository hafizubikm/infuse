import XCTest
import AVFoundation
@testable import Reel

/// The audio path follows the Sound mode while playing (as after an output-device change).
final class AudioModeSwitchingTests: XCTestCase {
    private final class Recorder {
        var paths: [String] = []
        var warnings: [String] = []
        var failure: String?
    }

    @MainActor
    private func makeEngine(_ name: String) throws -> (PlaybackEngine, Recorder) {
        let engine = PlaybackEngine(url: try TestMedia.url(name), videoLayer: AVSampleBufferDisplayLayer())
        let r = Recorder()
        engine.onEvent = { event in
            switch event {
            case .opened(let m): r.paths.append(m.audioRenderPath ?? "-")
            case .renderPaths(_, let a): r.paths.append(a ?? "-")
            case .warning(let w): r.warnings.append(w)
            case .failed(let f): r.failure = f
            default: break
            }
        }
        return (engine, r)
    }

    @MainActor
    private func spin(_ seconds: Double, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// E-AC-3 5.1: macOS decodes it for Spatial Audio; Virtual Surround and Stereo decode it with
    /// FFmpeg and render it to stereo — switching live keeps playing.
    @MainActor
    func testSwitchingRenderingWhilePlaying() throws {
        let (engine, r) = try makeEngine("hevc_hdr10_eac3.mkv")
        engine.open(startAt: 0, autoplay: true)
        spin(5) { engine.currentTime > 0.3 || r.failure != nil }
        XCTAssertNil(r.failure)
        XCTAssertTrue(r.paths.last?.contains("decoded by macOS · Apple Spatial Audio") == true, "\(r.paths)")

        let steps: [(AudioRendering, String)] = [
            (.virtualSurround, "decoded by FFmpeg → Virtual Surround (HRTF) → stereo"),
            (.stereo, "decoded by FFmpeg → stereo downmix"),
            (.spatial, "decoded by macOS · Apple Spatial Audio"),
        ]
        for (rendering, expected) in steps {
            let before = engine.currentTime
            let count = r.paths.count
            engine.setAudioRendering(rendering)
            spin(4) { (r.paths.count > count && engine.currentTime > before + 0.2) || r.failure != nil }
            XCTAssertTrue(r.paths.last?.contains(expected) == true, "\(rendering): \(r.paths)")
            XCTAssertGreaterThan(engine.currentTime, before, "still playing after switching to \(rendering)")
        }
        print("audio mode switching paths: \(r.paths)")
        XCTAssertNil(r.failure)
        XCTAssertFalse(r.warnings.contains { $0.hasPrefix("Audio stopped") }, "\(r.warnings)")
        engine.close()
    }

    /// Opening straight into Virtual Surround (a remembered headphone) with FLAC 7.1.
    @MainActor
    func testOpeningInVirtualSurround() throws {
        let (engine, r) = try makeEngine("h264_flac71.mkv")
        engine.setAudioRendering(.virtualSurround)
        engine.open(startAt: 0, autoplay: true)
        spin(5) { engine.currentTime > 0.8 || r.failure != nil }
        XCTAssertNil(r.failure)
        XCTAssertTrue(r.paths.first?.hasPrefix("FLAC 7.1") == true, "\(r.paths)")
        XCTAssertTrue(r.paths.first?.contains("Virtual Surround") == true, "\(r.paths)")
        XCTAssertGreaterThan(engine.currentTime, 0.8)
        XCTAssertFalse(r.warnings.contains { $0.hasPrefix("Audio stopped") }, "\(r.warnings)")
        engine.close()
    }

    /// Stereo sources aren't virtualized: they keep their normal path, just without spatialization.
    @MainActor
    func testStereoSourceInVirtualSurround() throws {
        let (engine, r) = try makeEngine("h264_aac.mp4")
        engine.setAudioRendering(.virtualSurround)
        engine.open(startAt: 0, autoplay: false)
        spin(5) { !r.paths.isEmpty || r.failure != nil }
        XCTAssertEqual(r.paths.first.map { $0.contains("decoded by macOS · no spatial processing") }, true, "\(r.paths)")
        XCTAssertTrue(engine.audioRenderer.allowedAudioSpatializationFormats.isEmpty)
        engine.close()
    }
}
