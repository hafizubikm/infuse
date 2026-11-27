import XCTest
import AVFoundation
import CoreGraphics
import CFFmpeg
@testable import Reel

final class SubtitleRenderTests: XCTestCase {
    /// RGBA bytes of an image (premultiplied), row 0 = top.
    private func pixels(_ image: CGImage) -> (data: [UInt8], width: Int, height: Int) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (data, w, h)
    }

    private func opaqueWhiteCount(_ p: (data: [UInt8], width: Int, height: Int), rows: Range<Int>) -> Int {
        var n = 0
        for y in rows {
            for x in 0..<p.width {
                let o = (y * p.width + x) * 4
                if p.data[o] > 230, p.data[o + 1] > 230, p.data[o + 2] > 230, p.data[o + 3] > 230 { n += 1 }
            }
        }
        return n
    }

    func testTextIsDrawnNearTheBottomInWhite() throws {
        let event = try XCTUnwrap(ASSEvent.parse("0,0,Default,,0,0,0,,Hello subtitles", script: ASSScript()))
        let cue = SubtitleCue(start: 0, end: 1, content: .text([event]))
        let image = try XCTUnwrap(SubtitleRenderer.render([cue], size: CGSize(width: 640, height: 360),
                                                          pixelScale: 1, style: .init()))
        let p = pixels(image)
        XCTAssertEqual(p.width, 640)
        XCTAssertGreaterThan(opaqueWhiteCount(p, rows: 260..<360), 200, "white glyphs expected near the bottom")
        XCTAssertEqual(opaqueWhiteCount(p, rows: 0..<200), 0, "nothing in the upper part")
    }

    func testTopAlignedSignIsDrawnAtTheTop() throws {
        let event = try XCTUnwrap(ASSEvent.parse("0,0,Default,,0,0,0,,{\\an8}Top", script: ASSScript()))
        let image = try XCTUnwrap(SubtitleRenderer.render([SubtitleCue(start: 0, end: 1, content: .text([event]))],
                                                          size: CGSize(width: 640, height: 360), pixelScale: 1, style: .init()))
        let p = pixels(image)
        XCTAssertGreaterThan(opaqueWhiteCount(p, rows: 0..<100), 50)
        XCTAssertEqual(opaqueWhiteCount(p, rows: 200..<360), 0)
    }

    func testBoxBackgroundStyle() throws {
        let event = try XCTUnwrap(ASSEvent.parse("0,0,Default,,0,0,0,,Boxed", script: ASSScript()))
        let image = try XCTUnwrap(SubtitleRenderer.render([SubtitleCue(start: 0, end: 1, content: .text([event]))],
                                                          size: CGSize(width: 640, height: 360), pixelScale: 1,
                                                          style: .init(scale: 1, background: .opaque, bottomOffset: 0)))
        let p = pixels(image)
        // Some dark, nearly opaque box pixels must exist around the text.
        var dark = 0
        for i in stride(from: 0, to: p.data.count, by: 4) where p.data[i + 3] > 200 && p.data[i] < 40 { dark += 1 }
        XCTAssertGreaterThan(dark, 500)
    }

    func testVobSubBitmapIsScaledOntoThePicture() throws {
        let file = try MediaFile(url: try TestMedia.url("vobsub.mkv"))
        let st = try XCTUnwrap(file.stream(at: 0))
        let decoder = try SubtitleDecoder(stream: st, startTime: 0)
        let raw = try XCTUnwrap(av_packet_alloc())
        var rawOpt: UnsafeMutablePointer<AVPacket>? = raw
        defer { av_packet_free(&rawOpt) }
        XCTAssertGreaterThanOrEqual(av_read_frame(file.formatContext, raw), 0)
        let cue = try XCTUnwrap(decoder.decode(try XCTUnwrap(Packet(moving: raw, generation: 0))).first)
        // 720×480 canvas shown at 1440×960: the 200×40 box at (260,400) becomes 400×80 at (520,800).
        let image = try XCTUnwrap(SubtitleRenderer.render([cue], size: CGSize(width: 1440, height: 960),
                                                          pixelScale: 1, style: .init()))
        let p = pixels(image)
        let centre = (840 * p.width + 720) * 4
        XCTAssertEqual(Array(p.data[centre..<centre + 4]), [255, 255, 255, 255])
        let outside = (500 * p.width + 720) * 4
        XCTAssertEqual(p.data[outside + 3], 0)
    }
}

final class SubtitlePlaybackTests: XCTestCase {
    @MainActor
    private func open(_ name: String) throws -> (PlaybackEngine, PlaybackEngine.OpenedMedia) {
        let engine = PlaybackEngine(url: try TestMedia.url(name), videoLayer: AVSampleBufferDisplayLayer())
        var opened: PlaybackEngine.OpenedMedia?
        engine.onEvent = { if case .opened(let m) = $0 { opened = m } }
        engine.open(startAt: 0, autoplay: false)
        let deadline = Date().addingTimeInterval(5)
        while opened == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return (engine, try XCTUnwrap(opened))
    }

    @MainActor
    func testEmbeddedTracksAndForcedDefault() throws {
        let (engine, media) = try open("h264_srt_ass.mkv")
        defer { engine.close() }
        let tracks = media.subtitles.tracks
        XCTAssertEqual(tracks.map(\.format), ["SRT", "ASS"])
        // The Japanese ASS track is flagged forced, but the file has no audio language to match it
        // against, so it is chosen as the forced default.
        XCTAssertEqual(media.defaultSubtitleID, tracks[1].id)
        media.subtitles.select(tracks[0].id)
        let deadline = Date().addingTimeInterval(5)
        while media.subtitles.activeCues(at: 1.0).isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(media.subtitles.activeCues(at: 1.0).count, 1)
    }

    @MainActor
    func testSidecarFileIsLoaded() throws {
        let (engine, media) = try open("h264_aac.mp4")
        defer { engine.close() }
        let deadline = Date().addingTimeInterval(5)
        while !media.subtitles.tracks.contains(where: \.isExternal) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let external = try XCTUnwrap(media.subtitles.tracks.first(where: \.isExternal))
        XCTAssertEqual(external.format, "SRT")
        XCTAssertTrue(external.menuTitle.hasSuffix("External"))
        media.subtitles.select(external.id)
        XCTAssertEqual(media.subtitles.activeCues(at: 2.0).count, 1)
    }
}
