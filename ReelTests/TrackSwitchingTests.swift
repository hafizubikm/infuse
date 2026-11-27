import XCTest
import AVFoundation
@testable import Reel

final class TrackSwitchingTests: XCTestCase {
    @MainActor
    func testSwitchingAudioTrackKeepsPlaying() throws {
        let engine = PlaybackEngine(url: try TestMedia.url("h264_two_audio.mkv"), videoLayer: AVSampleBufferDisplayLayer())
        var opened: PlaybackEngine.OpenedMedia?
        var audioPaths: [String] = []
        var failure: String?
        engine.onEvent = { event in
            switch event {
            case .opened(let m): opened = m; audioPaths.append(m.audioRenderPath ?? "-")
            case .renderPaths(_, let a): audioPaths.append(a ?? "-")
            case .failed(let f): failure = f
            default: break
            }
        }
        engine.open(startAt: 0, autoplay: true)
        func spin(_ seconds: Double, until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        spin(5) { engine.currentTime > 0.6 || failure != nil }
        let media = try XCTUnwrap(opened)
        XCTAssertEqual(media.info.audioStreams.count, 2)
        XCTAssertEqual(media.audioStream?.language, "eng")
        XCTAssertTrue(audioPaths.first?.hasPrefix("AAC") == true)

        let french = try XCTUnwrap(media.info.audioStreams.first { $0.language == "fre" })
        let before = engine.currentTime
        engine.selectAudio(streamIndex: french.index)
        spin(5) { audioPaths.count > 1 && engine.currentTime > before + 0.5 }
        XCTAssertTrue(audioPaths.last?.hasPrefix("AC-3 5.1") == true, "\(audioPaths)")
        XCTAssertGreaterThan(engine.currentTime, before, "playback continues after switching")
        XCTAssertNil(failure)
        engine.close()
    }

    @MainActor
    func testPreferredAudioStreamIsUsedOnOpen() throws {
        let probe = try MediaProbe.probe(url: try TestMedia.url("h264_two_audio.mkv"))
        let french = try XCTUnwrap(probe.audioStreams.first { $0.language == "fre" })
        let engine = PlaybackEngine(url: try TestMedia.url("h264_two_audio.mkv"), videoLayer: AVSampleBufferDisplayLayer())
        var opened: PlaybackEngine.OpenedMedia?
        engine.onEvent = { if case .opened(let m) = $0 { opened = m } }
        engine.open(startAt: 0, autoplay: false, preferredAudioStream: french.index)
        let deadline = Date().addingTimeInterval(5)
        while opened == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        XCTAssertEqual(opened?.audioStream?.index, french.index)
        engine.close()
    }
}
