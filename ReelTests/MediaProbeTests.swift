import XCTest
@testable import Reel

final class MediaProbeTests: XCTestCase {
    private func probe(_ name: String) throws -> MediaInfo {
        try MediaProbe.probe(url: try TestMedia.url(name))
    }

    func testHEVCHDR10WithEAC3InMatroska() throws {
        let info = try probe("hevc_hdr10_eac3.mkv")
        XCTAssertEqual(info.containerDisplayName, "Matroska")
        XCTAssertEqual(info.duration ?? 0, 3, accuracy: 0.2)

        let video = try XCTUnwrap(info.primaryVideo)
        XCTAssertEqual(video.codecName, "hevc")
        let v = try XCTUnwrap(video.video)
        XCTAssertEqual(v.width, 640)
        XCTAssertEqual(v.height, 360)
        XCTAssertEqual(v.bitDepth, 10)
        XCTAssertEqual(v.frameRate ?? 0, 23.976, accuracy: 0.01)
        XCTAssertEqual(v.hdr, .hdr10)
        XCTAssertEqual(v.color.primaries, ColorDescription.h273BT2020Primaries)
        XCTAssertEqual(v.color.transfer, ColorDescription.h273TransferPQ)
        XCTAssertEqual(v.color.matrix, ColorDescription.h273MatrixBT2020NCL)
        XCTAssertEqual(v.contentLightLevel, ContentLightLevel(maxCLL: 1000, maxFALL: 400))
        let md = try XCTUnwrap(v.masteringDisplay)
        XCTAssertEqual(md.maxLuminance ?? 0, 1000, accuracy: 0.5)
        XCTAssertEqual(md.minLuminance ?? 1, 0.0001, accuracy: 0.00005)
        XCTAssertEqual(md.red?.x ?? 0, 0.680, accuracy: 0.001)
        XCTAssertEqual(md.whitePoint?.y ?? 0, 0.3290, accuracy: 0.001)

        let audio = try XCTUnwrap(info.primaryAudio)
        XCTAssertEqual(audio.codecName, "eac3")
        XCTAssertEqual(audio.language, "eng")
        XCTAssertEqual(audio.audio?.channels, 6)
        XCTAssertEqual(audio.audio?.sampleRate, 48000)
        XCTAssertEqual(TrackLabels.audioFormat(audio), "E-AC-3 5.1")
        XCTAssertEqual(info.badges, ["HDR10"])
    }

    func testHEVCHDR10InMP4() throws {
        let info = try probe("hevc_hdr10_aac.mp4")
        XCTAssertEqual(info.containerDisplayName, "MP4")
        XCTAssertEqual(info.primaryVideo?.codecName, "hevc")
        XCTAssertEqual(info.primaryVideo?.video?.hdr, .hdr10)
        XCTAssertEqual(info.primaryAudio?.codecName, "aac")
        XCTAssertEqual(info.primaryAudio?.audio?.channelsDescription, "Stereo")
    }

    func testH264AACInMP4() throws {
        let info = try probe("h264_aac.mp4")
        XCTAssertEqual(info.primaryVideo?.codecName, "h264")
        XCTAssertEqual(info.primaryVideo?.video?.bitDepth, 8)
        XCTAssertEqual(info.primaryVideo?.video?.hdr, .sdr)
        XCTAssertEqual(info.primaryAudio?.codecName, "aac")
        XCTAssertTrue(info.badges.isEmpty)
    }

    func testTransportStreams() throws {
        let ts = try probe("h264_ac3.ts")
        XCTAssertEqual(ts.containerDisplayName, "MPEG-TS")
        XCTAssertEqual(ts.primaryVideo?.codecName, "h264")
        XCTAssertEqual(ts.primaryAudio?.codecName, "ac3")
        XCTAssertEqual(ts.primaryAudio?.audio?.channelsDescription, "5.1")

        let m2ts = try probe("h264_aac.m2ts")
        XCTAssertEqual(m2ts.containerDisplayName, "M2TS")
        XCTAssertEqual(m2ts.primaryAudio?.codecName, "aac")
    }

    func testHLGInQuickTime() throws {
        let info = try probe("hevc_hlg_aac.mov")
        XCTAssertEqual(info.containerDisplayName, "QuickTime")
        XCTAssertEqual(info.primaryVideo?.video?.hdr, .hlg)
        XCTAssertEqual(info.badges, ["HLG"])
    }

    func testAV1AndOpus() throws {
        let info = try probe("av1_opus.mkv")
        XCTAssertEqual(info.primaryVideo?.codecName, "av1")
        XCTAssertEqual(info.primaryVideo?.video?.bitDepth, 10)
        XCTAssertEqual(info.primaryAudio?.codecName, "opus")
        XCTAssertEqual(info.primaryAudio?.audio?.channels, 6)
    }

    func testLosslessAndDTSAudio() throws {
        let truehd = try probe("h264_truehd51.mkv")
        XCTAssertEqual(truehd.primaryAudio?.codecName, "truehd")
        XCTAssertEqual(truehd.primaryAudio?.audio?.channelsDescription, "5.1")

        let dts = try probe("h264_dts51.mkv")
        XCTAssertEqual(dts.primaryAudio?.codecName, "dts")
        XCTAssertEqual(dts.primaryAudio?.audio?.channels, 6)

        let flac = try probe("h264_flac71.mkv")
        XCTAssertEqual(flac.primaryAudio?.codecName, "flac")
        XCTAssertEqual(flac.primaryAudio?.audio?.channelsDescription, "7.1")
    }

    func testLegacyCodecs() throws {
        let mpeg2 = try probe("mpeg2_mp2.ts")
        XCTAssertEqual(mpeg2.primaryVideo?.codecName, "mpeg2video")
        XCTAssertEqual(mpeg2.primaryVideo?.codecDisplayName, "MPEG-2")
        XCTAssertEqual(mpeg2.primaryAudio?.codecName, "mp2")

        let avi = try probe("mpeg4_mp3.avi")
        XCTAssertEqual(avi.containerDisplayName, "AVI")
        XCTAssertEqual(avi.primaryVideo?.codecName, "mpeg4")
        XCTAssertEqual(avi.primaryAudio?.codecName, "mp3")

        let webm = try probe("vp9_hdr_opus.webm")
        XCTAssertEqual(webm.containerDisplayName, "WebM")
        XCTAssertEqual(webm.primaryVideo?.codecName, "vp9")
        XCTAssertEqual(webm.primaryVideo?.video?.hdr, .hdr10)
    }

    func testEmbeddedSubtitles() throws {
        let mkv = try probe("h264_srt_ass.mkv")
        let subs = mkv.subtitleStreams
        XCTAssertEqual(subs.map(\.codecName), ["subrip", "ass"])
        XCTAssertEqual(subs[0].language, "eng")
        XCTAssertEqual(subs[1].language, "jpn")
        XCTAssertTrue(subs[1].isForced)
        XCTAssertEqual(subs[0].subtitle?.isBitmap, false)
        XCTAssertEqual(TrackLabels.subtitleFormat(subs[1]), "ASS (Forced)")

        let mp4 = try probe("h264_movtext.mp4")
        XCTAssertEqual(mp4.subtitleStreams.first?.codecName, "mov_text")
    }

    func testDolbyVisionProfile81() throws {
        for name in ["dv_p81.mkv", "dv_p81.mp4"] {
            let info = try probe(name)
            let v = try XCTUnwrap(info.primaryVideo?.video, name)
            XCTAssertEqual(v.hdr, .dolbyVision, name)
            let dv = try XCTUnwrap(v.dolbyVision, name)
            XCTAssertEqual(dv.profile, 8, name)
            XCTAssertEqual(dv.level, 1, name)
            XCTAssertEqual(dv.blSignalCompatibilityID, 1, name)
            XCTAssertTrue(dv.rpuPresent, name)
            XCTAssertTrue(dv.blPresent, name)
            XCTAssertFalse(dv.elPresent, name)
            XCTAssertEqual(dv.profileString, "8.1", name)
            XCTAssertFalse(dv.isDualLayer, name)
            XCTAssertEqual(info.badges, ["DV"], name)
            XCTAssertEqual(TrackLabels.hdrDescription(v), "Dolby Vision 8.1", name)
        }
    }

    func testDolbyVisionProfile5() throws {
        let info = try probe("dv_p5.mkv")
        let dv = try XCTUnwrap(info.primaryVideo?.video?.dolbyVision)
        XCTAssertEqual(dv.profile, 5)
        XCTAssertEqual(dv.blSignalCompatibilityID, 0)
        XCTAssertEqual(dv.profileString, "5")
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try MediaProbe.probe(url: URL(fileURLWithPath: "/nonexistent/file.mkv")))
    }
}
