import XCTest
import AVFoundation
import CoreMedia
import VideoToolbox
import CFFmpeg
@testable import Reel

final class DolbyVisionFormatTests: XCTestCase {
    /// Keeps the MediaFile alive alongside its stream pointer (the stream is freed with the file).
    private struct Opened {
        let file: MediaFile
        let video: StreamInfo
        var stream: UnsafeMutablePointer<AVStream> { file.stream(at: video.index)! }
        var details: VideoDetails { video.video! }
    }

    private func open(_ name: String) throws -> Opened {
        let media = try MediaFile(url: try TestMedia.url(name))
        let vs = try XCTUnwrap(media.info.primaryVideo)
        XCTAssertNotNil(vs.video)
        return Opened(file: media, video: vs)
    }

    private func atoms(_ format: VideoTrackFormat) -> [String: Data] {
        let ext = CMFormatDescriptionGetExtensions(format.formatDescription) as? [String: Any] ?? [:]
        return ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Data] ?? [:]
    }

    func testProfile81IsNativeDolbyVision() throws {
        for name in ["dv_p81.mkv", "dv_p81.mp4"] {
            let o = try open(name)
            let format = try VideoFormatFactory.make(stream: o.stream, details: o.details)
            XCTAssertEqual(format.codecType, kCMVideoCodecType_DolbyVisionHEVC, name)
            XCTAssertEqual(format.dolbyVisionMode, .native, name)
            XCTAssertTrue(format.canFallBackToBaseLayer, name)
            XCTAssertTrue(format.droppedNALTypes.isEmpty, "RPUs must stay in the stream")
            let a = atoms(format)
            XCTAssertNotNil(a["hvcC"], name)
            XCTAssertEqual(a["dvvC"], Data([0x01, 0x00, 0x10, 0x0D, 0x10] + [UInt8](repeating: 0, count: 19)), name)
            XCTAssertEqual(format.renderDescription, "Dolby Vision Profile 8.1")
        }
    }

    func testProfile5IsNativeWithoutFallback() throws {
        let o = try open("dv_p5.mkv")
        let format = try VideoFormatFactory.make(stream: o.stream, details: o.details)
        XCTAssertEqual(format.codecType, kCMVideoCodecType_DolbyVisionHEVC)
        XCTAssertNotNil(atoms(format)["dvcC"])
        XCTAssertFalse(format.canFallBackToBaseLayer, "profile 5 has no compatible base layer")
    }

    func testBaseLayerPolicyAndSimulatedProfile7StripRPU() throws {
        let o = try open("dv_p81.mkv")
        let (media, vs, st) = (o.file, o.video, o.stream)
        var details = o.details
        // Pretend the stream is Blu-ray dual-layer profile 7.
        details.dolbyVision = DolbyVisionConfig(profile: 7, level: 6, rpuPresent: true, elPresent: true,
                                                blPresent: true, blSignalCompatibilityID: 6)
        let p7 = try VideoFormatFactory.make(stream: st, details: details)
        XCTAssertEqual(p7.codecType, kCMVideoCodecType_HEVC)
        XCTAssertEqual(p7.dolbyVisionMode, .baseLayerHDR10)
        XCTAssertEqual(p7.droppedNALTypes, [62, 63])
        XCTAssertEqual(p7.renderDescription, "Dolby Vision Profile 7 → playing HDR10 base layer")
        XCTAssertNil(atoms(p7)["dvcC"])

        let fallback = try VideoFormatFactory.make(stream: st, details: try XCTUnwrap(vs.video), dolbyVision: .baseLayerOnly)
        XCTAssertEqual(fallback.codecType, kCMVideoCodecType_HEVC)
        XCTAssertFalse(fallback.canFallBackToBaseLayer)

        // The rewritten samples contain no RPU NAL units and still decode.
        let builder = VideoSampleBuilder(format: p7, timing: StreamTimeConverter(timeBase: st.pointee.time_base, startTime: 0),
                                         frameRate: 24, isMatroska: true)
        var session: VTDecompressionSession?
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: p7.formatDescription,
                                                    decoderSpecification: nil, imageBufferAttributes: nil,
                                                    outputCallback: nil, decompressionSessionOut: &session), noErr)
        let s = try XCTUnwrap(session)
        defer { VTDecompressionSessionInvalidate(s) }
        final class Count: @unchecked Sendable { var frames = 0; var errors = 0 }
        let count = Count()
        let raw = try XCTUnwrap(av_packet_alloc())
        var rawOpt: UnsafeMutablePointer<AVPacket>? = raw
        defer { av_packet_free(&rawOpt) }
        var checked = 0
        while checked < 20, av_read_frame(media.formatContext, raw) >= 0 {
            guard Int(raw.pointee.stream_index) == vs.index, let p = Packet(moving: raw, generation: 0) else {
                av_packet_unref(raw); continue
            }
            // Source packets do carry RPUs …
            let srcTypes = NALUtils.lengthPrefixedUnits(p.bytes, lengthSize: 4)!.map { NALUtils.nalType(p.bytes[$0.lowerBound], codec: .hevc) }
            XCTAssertTrue(srcTypes.contains(62))
            let sample = try XCTUnwrap(builder.makeSample(p, displayFrom: .zero))
            // … the rewritten sample does not.
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample.buffer))
            var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes)
            let outTypes = bytes.withUnsafeBytes { b in
                NALUtils.lengthPrefixedUnits(b, lengthSize: 4)!.map { NALUtils.nalType(b[$0.lowerBound], codec: .hevc) }
            }
            XCTAssertFalse(outTypes.contains(62))
            XCTAssertFalse(outTypes.contains(63))
            VTDecompressionSessionDecodeFrame(s, sampleBuffer: sample.buffer, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                if status != noErr { count.errors += 1 } else if image != nil { count.frames += 1 }
            }
            checked += 1
        }
        VTDecompressionSessionWaitForAsynchronousFrames(s)
        XCTAssertEqual(count.errors, 0)
        XCTAssertGreaterThan(count.frames, 10)
    }

    func testNativeProfile81DecodesWhereSupported() throws {
        let o = try open("dv_p81.mkv")
        let (media, vs, st) = (o.file, o.video, o.stream)
        let format = try VideoFormatFactory.make(stream: st, details: o.details)
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format.formatDescription,
                                                  decoderSpecification: nil, imageBufferAttributes: nil,
                                                  outputCallback: nil, decompressionSessionOut: &session)
        guard status == noErr, let s = session else {
            throw XCTSkip("No Dolby Vision decoder on this machine (status \(status))")
        }
        defer { VTDecompressionSessionInvalidate(s) }
        let builder = VideoSampleBuilder(format: format, timing: StreamTimeConverter(timeBase: st.pointee.time_base, startTime: 0),
                                         frameRate: 24, isMatroska: true)
        final class Count: @unchecked Sendable { var frames = 0; var errors = 0 }
        let count = Count()
        let raw = try XCTUnwrap(av_packet_alloc())
        var rawOpt: UnsafeMutablePointer<AVPacket>? = raw
        defer { av_packet_free(&rawOpt) }
        var fed = 0
        while fed < 20, av_read_frame(media.formatContext, raw) >= 0 {
            guard Int(raw.pointee.stream_index) == vs.index, let p = Packet(moving: raw, generation: 0),
                  let sample = builder.makeSample(p, displayFrom: .zero) else { av_packet_unref(raw); continue }
            VTDecompressionSessionDecodeFrame(s, sampleBuffer: sample.buffer, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                if status != noErr { count.errors += 1 } else if image != nil { count.frames += 1 }
            }
            fed += 1
        }
        VTDecompressionSessionWaitForAsynchronousFrames(s)
        XCTAssertEqual(count.errors, 0)
        XCTAssertGreaterThan(count.frames, 10)
    }
}

final class AudioFeatureDetectorTests: XCTestCase {
    func testDetectsCandidatesAndRewinds() throws {
        let file = try MediaFile(url: try TestMedia.url("hevc_hdr10_eac3.mkv"))
        let audio = try XCTUnwrap(file.info.primaryAudio)
        let features = AudioFeatureDetector.detect(in: file)
        XCTAssertEqual(features[audio.index], AudioFeatureDetector.Features(isAtmos: false, isDTSX: false))

        // Reading continues from the start of the file.
        let raw = try XCTUnwrap(av_packet_alloc())
        var rawOpt: UnsafeMutablePointer<AVPacket>? = raw
        defer { av_packet_free(&rawOpt) }
        XCTAssertGreaterThanOrEqual(av_read_frame(file.formatContext, raw), 0)
        let tb = file.stream(at: Int(raw.pointee.stream_index))!.pointee.time_base
        XCTAssertLessThan(Double(raw.pointee.pts) * tb.doubleValue, 0.1)
        av_packet_unref(raw)
    }

    func testTrueHDAndDTSAreProbedWithoutFalsePositives() throws {
        for name in ["h264_truehd51.mkv", "h264_dts51.mkv"] {
            let file = try MediaFile(url: try TestMedia.url(name))
            let audio = try XCTUnwrap(file.info.primaryAudio)
            let features = AudioFeatureDetector.detect(in: file)
            XCTAssertNotNil(features[audio.index], name)
            file.detectAudioFeatures()
            XCTAssertEqual(file.info.primaryAudio?.audio?.isAtmos, false, name)
            XCTAssertEqual(file.info.primaryAudio?.audio?.isDTSX, false, name)
        }
    }

    func testNonCandidatesAreSkipped() throws {
        let file = try MediaFile(url: try TestMedia.url("h264_aac.mp4"))
        XCTAssertTrue(AudioFeatureDetector.detect(in: file).isEmpty)
    }
}

final class DolbyVisionEngineTests: XCTestCase {
    /// Native Dolby Vision where the machine supports it; otherwise the engine must fall back
    /// to the HDR10 base layer by itself and keep playing.
    @MainActor
    func testProfile81PlaysNativelyOrFallsBack() throws {
        let url = try TestMedia.url("dv_p81.mkv")
        let layer = AVSampleBufferDisplayLayer()
        let engine = PlaybackEngine(url: url, videoLayer: layer)
        var opened: PlaybackEngine.OpenedMedia?
        var failure: String?
        var paths: [String] = []
        engine.onEvent = { event in
            switch event {
            case .opened(let m): opened = m; paths.append(m.videoRenderPath ?? "")
            case .failed(let f): failure = f
            case .renderPaths(let v, _): paths.append(v ?? "")
            default: break
            }
        }
        engine.open(startAt: 0, autoplay: true)
        let deadline = Date().addingTimeInterval(8)
        while engine.currentTime < 1.0 && failure == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertNotNil(opened)
        XCTAssertNil(failure)
        XCTAssertGreaterThan(engine.currentTime, 1.0)
        XCTAssertEqual(paths.first, "Dolby Vision Profile 8.1 · hardware decode")
        print("Dolby Vision render paths on this machine: \(paths)")
        engine.close()
    }
}
