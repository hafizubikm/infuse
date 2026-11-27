import XCTest
import CFFmpeg
@testable import Reel

final class ASSParserTests: XCTestCase {
    func testColours() {
        XCTAssertEqual(SubtitleColor(ass: "&H00FFFFFF"), .white)
        XCTAssertEqual(SubtitleColor(ass: "&H0000FFFF&"), SubtitleColor(red: 1, green: 1, blue: 0, alpha: 1)) // BGR → yellow
        XCTAssertEqual(SubtitleColor(ass: "&H80000000")!.alpha, 1 - 128.0 / 255, accuracy: 0.001)
        XCTAssertNil(SubtitleColor(ass: "nonsense"))
    }

    func testHeaderAndOverrides() throws {
        let header = """
        [Script Info]
        PlayResX: 640
        PlayResY: 360

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Helvetica,24,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,1,2,20,20,20,1
        Style: Sign,Helvetica,20,&H0000FFFF,&H000000FF,&H00000000,&H80000000,-1,0,0,0,100,100,0,0,1,1,0,8,10,10,10,1
        """
        let script = ASSScript.parse(header: header)
        XCTAssertEqual(script.playResX, 640)
        XCTAssertEqual(script.playResY, 360)
        XCTAssertEqual(script.styles["Sign"]?.bold, true)
        XCTAssertEqual(script.styles["Sign"]?.alignment, 8)

        let e = try XCTUnwrap(ASSEvent.parse("1,0,Default,,0,0,0,,Styled {\\i1}dialogue{\\i0}\\Nline two", script: script))
        XCTAssertEqual(e.plainText, "Styled dialogue\nline two")
        XCTAssertEqual(e.runs.map(\.italic), [false, true, false])
        XCTAssertEqual(e.alignment, 2)

        let sign = try XCTUnwrap(ASSEvent.parse("2,0,Sign,,0,0,0,,{\\an7\\pos(320,40)\\c&H0000FF&\\fs30}Top sign", script: script))
        XCTAssertEqual(sign.alignment, 7)
        XCTAssertEqual(sign.position?.x, 320)
        XCTAssertEqual(sign.position?.y, 40)
        XCTAssertEqual(sign.runs.first?.color, SubtitleColor(red: 1, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(sign.runs.first?.fontSize, 30)
        XCTAssertEqual(sign.runs.first?.bold, true)

        // Drawings are dropped, \h is a non-breaking space, full "Dialogue:" lines work too.
        let d = try XCTUnwrap(ASSEvent.parse("Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,A{\\p1}m 0 0 l 10 10{\\p0}\\hB", script: script))
        XCTAssertEqual(d.plainText, "A\u{00A0}B")
        XCTAssertEqual(ASSScript.ssaToNumpad(6), 8)   // SSA "top centre"
    }
}

final class CueStoreTests: XCTestCase {
    private func text(_ s: String) -> SubtitleContent {
        var e = ASSEvent()
        e.runs = [ASSRun(text: s, bold: false, italic: false, underline: false, fontName: "", fontSize: 18,
                         color: .white, outlineColor: .black)]
        return .text([e])
    }

    func testActiveDedupeAndPrune() {
        let store = CueStore()
        store.add(SubtitleCue(start: 1, end: 2, content: text("a")))
        store.add(SubtitleCue(start: 1.5, end: 3, content: text("b")))
        store.add(SubtitleCue(start: 1, end: 2, content: text("a")))      // duplicate after a seek
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.active(at: 1.7).count, 2)
        XCTAssertEqual(store.active(at: 2.5).count, 1)
        XCTAssertTrue(store.active(at: 0.5).isEmpty)
        store.add(SubtitleCue(start: 200, end: 201, content: text("late")))
        store.prune(before: 200)
        XCTAssertEqual(store.count, 1)
    }

    func testOpenEndedBitmapsCloseAtNextDisplaySet() {
        let store = CueStore()
        let bmp = SubtitleBitmap(x: 0, y: 0, width: 1, height: 1, rgba: [255, 255, 255, 255], forced: false)
        store.add(SubtitleCue(start: 1, end: nil, content: .bitmaps([bmp], canvasWidth: 720, canvasHeight: 480)))
        XCTAssertEqual(store.active(at: 5).count, 1)
        store.add(SubtitleCue(start: 3, end: 3, content: .bitmaps([], canvasWidth: 720, canvasHeight: 480)))  // clear
        XCTAssertEqual(store.active(at: 2).count, 1)
        XCTAssertTrue(store.active(at: 3.5).isEmpty)
    }
}

final class SubtitleDecodingTests: XCTestCase {
    private func cues(_ name: String, stream n: Int = 0) throws -> (SubtitleDecoder, [SubtitleCue]) {
        let file = try MediaFile(url: try TestMedia.url(name))
        let s = try XCTUnwrap(file.info.subtitleStreams.dropFirst(n).first)
        let decoder = try SubtitleDecoder(stream: try XCTUnwrap(file.stream(at: s.index)), startTime: file.startTime)
        var out: [SubtitleCue] = []
        let raw = try XCTUnwrap(av_packet_alloc())
        var rawOpt: UnsafeMutablePointer<AVPacket>? = raw
        defer { av_packet_free(&rawOpt) }
        while av_read_frame(file.formatContext, raw) >= 0 {
            guard Int(raw.pointee.stream_index) == s.index, let p = Packet(moving: raw, generation: 0) else {
                av_packet_unref(raw); continue
            }
            out += decoder.decode(p)
        }
        return (decoder, out)
    }

    private func events(_ cue: SubtitleCue) -> [ASSEvent] {
        if case .text(let e) = cue.content { return e }
        return []
    }

    func testSubRipInMatroska() throws {
        let (_, c) = try cues("h264_srt_ass.mkv")
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c[0].start, 0.5, accuracy: 0.01)
        XCTAssertEqual(c[0].end ?? 0, 1.5, accuracy: 0.01)
        let e = try XCTUnwrap(events(c[0]).first)
        XCTAssertEqual(e.plainText, "Hello from Reel")
        XCTAssertEqual(e.runs.last?.italic, true)
        XCTAssertEqual(events(c[1]).first?.plainText, "Second line\nwith a break")
    }

    func testASSInMatroskaKeepsStylesAndPositions() throws {
        let (decoder, c) = try cues("h264_srt_ass.mkv", stream: 1)
        XCTAssertEqual(decoder.script.playResY, 360)
        XCTAssertEqual(c.count, 2)
        let sign = try XCTUnwrap(c.flatMap(events).first { $0.styleName == "Sign" })
        XCTAssertEqual(sign.alignment, 8)
        XCTAssertEqual(sign.position?.x, 320)
        XCTAssertEqual(sign.runs.first?.color, SubtitleColor(red: 1, green: 1, blue: 0, alpha: 1))
        XCTAssertEqual(sign.plainText, "A sign at the top")
    }

    func testMovText() throws {
        let (_, c) = try cues("h264_movtext.mp4")
        XCTAssertEqual(c.count, 2)
        XCTAssertTrue(events(c[0]).first?.plainText.contains("Reel") == true)
    }

    func testVobSubBitmaps() throws {
        let (_, c) = try cues("vobsub.mkv")
        XCTAssertEqual(c.count, 2)
        guard case .bitmaps(let rects, let w, let h) = c[0].content else { return XCTFail("not a bitmap cue") }
        XCTAssertEqual(w, 720)
        XCTAssertEqual(h, 480)
        let r = try XCTUnwrap(rects.first)
        XCTAssertEqual(r.width, 200)
        XCTAssertEqual(r.height, 40)
        let centre = ((r.height / 2) * r.width + r.width / 2) * 4
        XCTAssertEqual(Array(r.rgba[centre..<centre + 4]), [255, 255, 255, 255])   // white fill
        XCTAssertEqual(Array(r.rgba[0..<4]).last, 255)                             // opaque black border
        XCTAssertEqual(c[0].start, 0.5, accuracy: 0.01)
        XCTAssertEqual(c[0].end ?? 0, 1.5, accuracy: 0.05)
        XCTAssertFalse(c[0].isForced)
        XCTAssertTrue(c[1].isForced)
    }

    func testExternalSidecarDiscoveryAndLoading() throws {
        let video = try TestMedia.url("h264_aac.mp4")
        let found = ExternalSubtitles.find(for: video)
        XCTAssertEqual(found.map(\.url.lastPathComponent), ["h264_aac.srt"])
        let (loaded, codec) = try ExternalSubtitles.load(found[0].url)
        XCTAssertEqual(codec, "subrip")
        XCTAssertEqual(loaded.count, 2)

        XCTAssertEqual(ExternalSubtitles.languageCode("en"), "en")
        XCTAssertEqual(ExternalSubtitles.languageCode("english"), "eng")
        XCTAssertNil(ExternalSubtitles.languageCode("forced"))
    }

    func testDefaultSelection() {
        func track(_ id: String, lang: String?, forced: Bool = false, isDefault: Bool = false) -> SubtitleTrack {
            SubtitleTrack(id: id, source: .embedded(streamIndex: 0), language: lang, title: nil, format: "SRT",
                          isForced: forced, isDefault: isDefault, isHearingImpaired: false, isBitmap: false)
        }
        let tracks = [track("a", lang: "eng"), track("b", lang: "eng", forced: true), track("c", lang: "jpn", isDefault: true)]
        XCTAssertEqual(SubtitleSelector.defaultTrack(tracks, audioLanguage: "eng")?.id, "b")
        XCTAssertEqual(SubtitleSelector.defaultTrack(tracks, audioLanguage: "jpn")?.id, "c")
        XCTAssertNil(SubtitleSelector.defaultTrack([track("a", lang: "eng")], audioLanguage: "eng"))
        XCTAssertEqual(track("x", lang: "eng", forced: true).menuTitle.hasSuffix("SRT (Forced)"), true)
    }

    func testManagerDecodesWhileDemuxing() throws {
        let file = try MediaFile(url: try TestMedia.url("h264_srt_ass.mkv"), useCustomIO: true)
        let manager = SubtitleManager(file: file)
        XCTAssertEqual(manager.tracks.count, 2)
        let demuxer = Demuxer(file: file)
        demuxer.setActiveStreams(manager.embeddedStreamIndices)
        manager.attach(demuxer)
        demuxer.start()
        defer { demuxer.stop() }
        manager.select(manager.tracks[0].id)
        let deadline = Date().addingTimeInterval(5)
        while manager.activeCues(at: 2.0).isEmpty && Date() < deadline { usleep(10_000) }
        XCTAssertEqual(manager.activeCues(at: 2.0).count, 1)
        XCTAssertTrue(manager.activeCues(at: 1.6).isEmpty)
    }
}
