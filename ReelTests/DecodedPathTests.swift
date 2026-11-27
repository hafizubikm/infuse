import XCTest
import AVFoundation
import CoreMedia
import CoreVideo
import CFFmpeg
@testable import Reel

final class ChannelLayoutMapperTests: XCTestCase {
    private func tag(_ plan: ChannelLayoutPlan) -> AudioChannelLayoutTag {
        plan.layoutData.withUnsafeBytes { $0.load(as: AudioChannelLayout.self).mChannelLayoutTag }
    }

    func testStandardLayouts() {
        let s51: [Speaker] = [.frontLeft, .frontRight, .center, .lfe, .surroundLeft, .surroundRight]
        let p51 = ChannelLayoutMapper.plan(for: s51)
        XCTAssertEqual(tag(p51), kAudioChannelLayoutTag_MPEG_5_1_A)
        XCTAssertNil(p51.sourceIndexForOutput, "FFmpeg 5.1 order already matches L R C LFE Ls Rs")

        // FFmpeg 7.1 order FL FR FC LFE BL BR SL SR → Core Audio L R C LFE Ls Rs Rls Rrs.
        let s71: [Speaker] = [.frontLeft, .frontRight, .center, .lfe, .rearLeft, .rearRight, .surroundLeft, .surroundRight]
        let p71 = ChannelLayoutMapper.plan(for: s71)
        XCTAssertEqual(tag(p71), kAudioChannelLayoutTag_MPEG_7_1_C)
        XCTAssertEqual(p71.sourceIndexForOutput, [0, 1, 2, 3, 6, 7, 4, 5])
        let frame: [Float] = [0, 1, 2, 3, 4, 5, 6, 7]
        XCTAssertEqual(p71.reorder(frame + frame), [0, 1, 2, 3, 6, 7, 4, 5, 0, 1, 2, 3, 6, 7, 4, 5])

        XCTAssertEqual(tag(ChannelLayoutMapper.plan(for: [.frontLeft, .frontRight])), kAudioChannelLayoutTag_Stereo)
    }

    func testUnusualLayoutUsesChannelDescriptions() throws {
        let speakers: [Speaker] = [.frontLeft, .frontRight, .center, .lfe, .surroundLeft, .surroundRight, .rearCenter]
        let plan = ChannelLayoutMapper.plan(for: speakers)
        let layout = plan.layoutData.withUnsafeBytes { $0.load(as: AudioChannelLayout.self) }
        XCTAssertEqual(layout.mChannelLayoutTag, kAudioChannelLayoutTag_UseChannelDescriptions)
        XCTAssertEqual(layout.mNumberChannelDescriptions, 7)
        let fd = try ChannelLayoutMapper.pcmFormatDescription(sampleRate: 48000, plan: plan)
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(fd)).pointee
        XCTAssertEqual(asbd.mChannelsPerFrame, 7)
        XCTAssertEqual(asbd.mFormatID, kAudioFormatLinearPCM)
        var size = 0
        XCTAssertNotNil(CMAudioFormatDescriptionGetChannelLayout(fd, sizeOut: &size))
    }
}

/// FFmpeg video decoding → pixel buffers with the right format and colour attachments.
final class DecodedVideoTests: XCTestCase {
    private struct Result {
        var buffers: [CVPixelBuffer] = []
        var usesHardware: Bool?
    }

    private func decode(_ name: String, frames: Int = 8) throws -> Result {
        _ = VideoFormatFactory.registerSupplementalDecoders
        let file = try MediaFile(url: try TestMedia.url(name))
        let vs = try XCTUnwrap(file.info.primaryVideo)
        let st = try XCTUnwrap(file.stream(at: vs.index))
        let decoder = try VideoDecoder(stream: st)
        let factory = PixelBufferFactory(details: try XCTUnwrap(vs.video))
        let timing = StreamTimeConverter(timeBase: st.pointee.time_base, startTime: file.startTime)
        var result = Result()
        let raw = try XCTUnwrap(av_packet_alloc())
        var rawOpt: UnsafeMutablePointer<AVPacket>? = raw
        defer { av_packet_free(&rawOpt) }
        while result.buffers.count < frames, av_read_frame(file.formatContext, raw) >= 0 {
            guard Int(raw.pointee.stream_index) == vs.index, let p = Packet(moving: raw, generation: 0) else {
                av_packet_unref(raw); continue
            }
            decoder.decode(p) { frame in
                let pts = timing.time(frame.pointee.best_effort_timestamp)
                if let sb = factory.sampleBuffer(for: frame, pts: pts, duration: CMTime(value: 1, timescale: 24)),
                   let pb = CMSampleBufferGetImageBuffer(sb) {
                    XCTAssertTrue(CMSampleBufferIsValid(sb))
                    result.buffers.append(pb)
                }
            }
        }
        result.usesHardware = decoder.usesHardware
        XCTAssertGreaterThanOrEqual(result.buffers.count, frames, "\(name): too few frames")
        return result
    }

    private func attachment(_ pb: CVPixelBuffer, _ key: CFString) -> String? {
        CVBufferCopyAttachment(pb, key, nil) as? String
    }

    func testMPEG2() throws {
        let r = try decode("mpeg2_mp2.ts")
        let pb = try XCTUnwrap(r.buffers.first)
        XCTAssertEqual(CVPixelBufferGetWidth(pb), 640)
        XCTAssertNotNil(attachment(pb, kCVImageBufferYCbCrMatrixKey))
        print("MPEG-2 hardware decode: \(r.usesHardware ?? false)")
    }

    func testMPEG4ASPInAVI() throws {
        let r = try decode("mpeg4_mp3.avi")
        XCTAssertEqual(CVPixelBufferGetHeight(try XCTUnwrap(r.buffers.first)), 360)
    }

    func testHi10PDecodesToTenBit() throws {
        let r = try decode("h264_hi10p_aac.mkv")
        let pb = try XCTUnwrap(r.buffers.first)
        if r.usesHardware == false {
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(pb), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        }
    }

    func testVP9HDR10KeepsPQ() throws {
        let r = try decode("vp9_hdr_opus.webm")
        let pb = try XCTUnwrap(r.buffers.first)
        XCTAssertEqual(attachment(pb, kCVImageBufferTransferFunctionKey), kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        XCTAssertEqual(attachment(pb, kCVImageBufferColorPrimariesKey), kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        let format = CVPixelBufferGetPixelFormatType(pb)
        XCTAssertTrue([kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange]
                        .contains(format), "10-bit VP9 must stay 10-bit (got \(format))")
        print("VP9 hardware decode: \(r.usesHardware ?? false)")
    }

    func testHi10PIsRoutedToDecodedPath() throws {
        let info = try MediaProbe.probe(url: try TestMedia.url("h264_hi10p_aac.mkv"))
        XCTAssertTrue(VideoPathSelector.needsDecodedPath(try XCTUnwrap(info.primaryVideo)))
        let normal = try MediaProbe.probe(url: try TestMedia.url("h264_aac.mp4"))
        XCTAssertFalse(VideoPathSelector.needsDecodedPath(try XCTUnwrap(normal.primaryVideo)))
    }
}

/// End-to-end playback through the decoded paths.
final class DecodedPlaybackTests: XCTestCase {
    @MainActor
    private func play(_ name: String, until seconds: Double = 1.0) throws -> (PlaybackEngine.OpenedMedia?, String?, [String]) {
        let url = try TestMedia.url(name)
        let layer = AVSampleBufferDisplayLayer()
        let engine = PlaybackEngine(url: url, videoLayer: layer)
        var opened: PlaybackEngine.OpenedMedia?
        var failure: String?
        var videoPaths: [String] = []
        engine.onEvent = { event in
            switch event {
            case .opened(let m): opened = m; videoPaths.append(m.videoRenderPath ?? "-")
            case .renderPaths(let v, _): videoPaths.append(v ?? "-")
            case .failed(let f): failure = f
            default: break
            }
        }
        engine.open(startAt: 0, autoplay: true)
        let deadline = Date().addingTimeInterval(8)
        while engine.currentTime < seconds && failure == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNil(failure, name)
        XCTAssertGreaterThan(engine.currentTime, seconds * 0.9, "\(name): clock did not advance")
        XCTAssertNotEqual(layer.sampleBufferRenderer.status, .failed, name)
        print("\(name) render paths: video \(videoPaths), audio \(opened?.audioRenderPath ?? "-")")
        engine.close()
        return (opened, failure, videoPaths)
    }

    @MainActor func testMPEG2WithMP2() throws {
        let (opened, _, paths) = try play("mpeg2_mp2.ts")
        XCTAssertTrue(paths.last?.hasPrefix("MPEG-2 · FFmpeg") == true)
        XCTAssertTrue(opened?.audioRenderPath?.contains("decoded by FFmpeg") == true)
    }

    @MainActor func testTrueHDAudio() throws {
        let (opened, _, _) = try play("h264_truehd51.mkv")
        XCTAssertTrue(opened?.audioRenderPath?.hasPrefix("TrueHD 5.1") == true)
        XCTAssertTrue(opened?.audioRenderPath?.contains("decoded by FFmpeg") == true)
    }

    @MainActor func testDTSAndFLACAndPCM() throws {
        for name in ["h264_dts51.mkv", "h264_flac71.mkv", "h264_pcm51.mkv"] {
            let (opened, _, _) = try play(name, until: 0.8)
            XCTAssertTrue(opened?.audioRenderPath?.contains("decoded by FFmpeg") == true, name)
        }
    }

    @MainActor func testHi10PAndVP9AndAVI() throws {
        for name in ["h264_hi10p_aac.mkv", "vp9_hdr_opus.webm", "mpeg4_mp3.avi"] {
            let (_, _, paths) = try play(name, until: 0.8)
            XCTAssertTrue(paths.last?.contains("FFmpeg") == true, "\(name): \(paths)")
        }
    }
}
