import XCTest
import AVFoundation
import CoreMedia
import VideoToolbox
import CFFmpeg
@testable import Reel

/// Reads the first packets of a stream directly (no demux thread).
private func firstPackets(_ file: MediaFile, stream index: Int, count: Int) throws -> [Packet] {
    var out: [Packet] = []
    let raw = try XCTUnwrap(av_packet_alloc())
    var rawOpt: UnsafeMutablePointer<AVPacket>? = raw
    defer { av_packet_free(&rawOpt) }
    while out.count < count, av_read_frame(file.formatContext, raw) >= 0 {
        if Int(raw.pointee.stream_index) == index, let p = Packet(moving: raw, generation: 0) {
            out.append(p)
        } else {
            av_packet_unref(raw)
        }
    }
    return out
}

/// Builds VideoTrackFormats for each fixture and decodes real packets through VideoToolbox,
/// exactly as AVSampleBufferDisplayLayer would receive them.
final class VideoFormatTests: XCTestCase {
    private final class DecodeResult: @unchecked Sendable {
        var frames = 0
        var errors: [OSStatus] = []
        var transfer: CFString?
        var primaries: CFString?
    }

    private func decode(_ name: String, codecType: CMVideoCodecType, expectPacketFormat: VideoPacketFormat? = nil,
                        file: StaticString = #filePath, line: UInt = #line) throws -> (VideoTrackFormat, DecodeResult) {
        if codecType == kCMVideoCodecType_AV1 && !VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) {
            throw XCTSkip("No AV1 hardware decoder on this machine")
        }
        let media = try MediaFile(url: try TestMedia.url(name))
        let vs = try XCTUnwrap(media.info.primaryVideo, file: file, line: line)
        let st = try XCTUnwrap(media.stream(at: vs.index))
        let format = try VideoFormatFactory.make(stream: st, details: try XCTUnwrap(vs.video))
        XCTAssertEqual(format.codecType, codecType, file: file, line: line)
        if let expectPacketFormat { XCTAssertEqual(format.packetFormat, expectPacketFormat, file: file, line: line) }

        let builder = VideoSampleBuilder(format: format,
                                         timing: StreamTimeConverter(timeBase: st.pointee.time_base, startTime: media.startTime),
                                         frameRate: vs.video?.frameRate, isMatroska: media.info.formatName.hasPrefix("matroska"))
        let result = DecodeResult()
        var session: VTDecompressionSession?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format.formatDescription,
                                                  decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
                                                  outputCallback: nil, decompressionSessionOut: &session)
        XCTAssertEqual(status, noErr, "VTDecompressionSessionCreate", file: file, line: line)
        let s = try XCTUnwrap(session, file: file, line: line)
        defer { VTDecompressionSessionInvalidate(s) }

        for packet in try firstPackets(media, stream: vs.index, count: 30) {
            guard let sample = builder.makeSample(packet, displayFrom: .zero) else {
                XCTFail("Could not build sample buffer", file: file, line: line); continue
            }
            let st = VTDecompressionSessionDecodeFrame(s, sampleBuffer: sample.buffer, flags: [], infoFlagsOut: nil) {
                status, _, image, _, _ in
                if status != noErr { result.errors.append(status); return }
                guard let image else { return }
                result.frames += 1
                result.transfer = CVBufferCopyAttachment(image, kCVImageBufferTransferFunctionKey, nil) as! CFString?
                result.primaries = CVBufferCopyAttachment(image, kCVImageBufferColorPrimariesKey, nil) as! CFString?
            }
            if st != noErr { result.errors.append(st) }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(s)
        XCTAssertTrue(result.errors.isEmpty, "decode errors: \(result.errors)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(result.frames, 20, file: file, line: line)
        return (format, result)
    }

    func testHEVCHDR10Matroska() throws {
        let (format, r) = try decode("hevc_hdr10_eac3.mkv", codecType: kCMVideoCodecType_HEVC,
                                     expectPacketFormat: .lengthPrefixed(lengthSize: 4))
        let ext = CMFormatDescriptionGetExtensions(format.formatDescription) as? [String: Any] ?? [:]
        XCTAssertEqual(ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String,
                       kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
        XCTAssertEqual(ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String,
                       kCMFormatDescriptionColorPrimaries_ITU_R_2020 as String)
        XCTAssertEqual((ext[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] as? Data)?.count, 24)
        XCTAssertEqual((ext[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] as? Data)?.count, 4)
        XCTAssertEqual(r.transfer as String?, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        XCTAssertEqual(r.primaries as String?, kCVImageBufferColorPrimaries_ITU_R_2020 as String)
    }

    func testHEVCInMP4AndHLGInMOV() throws {
        _ = try decode("hevc_hdr10_aac.mp4", codecType: kCMVideoCodecType_HEVC)
        let (_, hlg) = try decode("hevc_hlg_aac.mov", codecType: kCMVideoCodecType_HEVC)
        XCTAssertEqual(hlg.transfer as String?, kCVImageBufferTransferFunction_ITU_R_2100_HLG as String)
    }

    func testH264InMP4() throws {
        _ = try decode("h264_aac.mp4", codecType: kCMVideoCodecType_H264, expectPacketFormat: .lengthPrefixed(lengthSize: 4))
    }

    func testH264AnnexBInTransportStreams() throws {
        _ = try decode("h264_ac3.ts", codecType: kCMVideoCodecType_H264, expectPacketFormat: .annexB)
        _ = try decode("h264_aac.m2ts", codecType: kCMVideoCodecType_H264, expectPacketFormat: .annexB)
    }

    func testAV1() throws {
        _ = try decode("av1_opus.mkv", codecType: kCMVideoCodecType_AV1, expectPacketFormat: .av1)
    }

    func testUnsupportedCodecIsRejected() throws {
        let media = try MediaFile(url: try TestMedia.url("mpeg2_mp2.ts"))
        let vs = try XCTUnwrap(media.info.primaryVideo)
        XCTAssertThrowsError(try VideoFormatFactory.make(stream: media.stream(at: vs.index)!, details: vs.video!))
    }
}

/// Checks that the passthrough formats (ESDS cookie, AC-3/E-AC-3 ASBDs) really decode with
/// Apple's decoders.
final class AudioFormatTests: XCTestCase {
    private func decodeFirstPackets(_ name: String, expectFormat: AudioFormatID,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let media = try MediaFile(url: try TestMedia.url(name))
        let audio = try XCTUnwrap(media.info.primaryAudio, file: file, line: line)
        let par = try XCTUnwrap(media.stream(at: audio.index)).pointee.codecpar.pointee
        let packets = try firstPackets(media, stream: audio.index, count: 8)
        let format = try AudioFormatFactory.makePassthrough(par: par, firstPacket: packets.first)
        let asbd = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(format.formatDescription)).pointee
        XCTAssertEqual(asbd.mFormatID, expectFormat, file: file, line: line)

        let inFormat = AVAudioFormat(cmAudioFormatDescription: format.formatDescription)
        let outFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate,
                                                    channels: inFormat.channelCount, interleaved: false))
        let converter = try XCTUnwrap(AVAudioConverter(from: inFormat, to: outFormat), file: file, line: line)
        var queue = packets
        var decodedFrames: AVAudioFrameCount = 0
        while !queue.isEmpty {
            let out = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8192))
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                guard !queue.isEmpty else { inputStatus.pointee = .endOfStream; return nil }
                let p = queue.removeFirst()
                var bytes = p.bytes
                if format.stripsADTSHeader, let h = AACConfig.parseADTS(bytes) {
                    bytes = UnsafeRawBufferPointer(rebasing: bytes[h.headerLength...])
                }
                let buffer = AVAudioCompressedBuffer(format: inFormat, packetCapacity: 1, maximumPacketSize: bytes.count)
                buffer.data.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
                buffer.packetDescriptions?.pointee = AudioStreamPacketDescription(
                    mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(bytes.count))
                buffer.packetCount = 1
                buffer.byteLength = UInt32(bytes.count)
                inputStatus.pointee = .haveData
                return buffer
            }
            XCTAssertNotEqual(status, .error, "\(error?.localizedDescription ?? "")", file: file, line: line)
            if status == .error { break }
            decodedFrames += out.frameLength
            if status == .endOfStream { break }
        }
        XCTAssertGreaterThan(decodedFrames, 2048, file: file, line: line)
    }

    func testAACFromMP4() throws { try decodeFirstPackets("h264_aac.mp4", expectFormat: kAudioFormatMPEG4AAC) }
    func testAACFromADTSInM2TS() throws { try decodeFirstPackets("h264_aac.m2ts", expectFormat: kAudioFormatMPEG4AAC) }
    func testAC3FromTS() throws { try decodeFirstPackets("h264_ac3.ts", expectFormat: kAudioFormatAC3) }
    func testEAC3FromMatroska() throws { try decodeFirstPackets("hevc_hdr10_eac3.mkv", expectFormat: kAudioFormatEnhancedAC3) }

    func testNonPassthroughCodecsAreRejected() throws {
        let media = try MediaFile(url: try TestMedia.url("h264_truehd51.mkv"))
        let a = try XCTUnwrap(media.info.primaryAudio)
        XCTAssertFalse(AudioFormatFactory.supportsPassthrough(codecID: media.stream(at: a.index)!.pointee.codecpar.pointee.codec_id))
    }
}

/// Plays a clip end-to-end through PlaybackEngine (renderers + synchronizer), headless.
final class PlaybackEngineTests: XCTestCase {
    @MainActor
    func testPlaysAndSeeks() throws {
        let url = try TestMedia.url("hevc_hdr10_aac.mp4")
        let layer = AVSampleBufferDisplayLayer()
        let engine = PlaybackEngine(url: url, videoLayer: layer)
        var opened: PlaybackEngine.OpenedMedia?
        var failure: String?
        var seekDone: Double?
        var ended = false
        engine.onEvent = { event in
            switch event {
            case .opened(let m): opened = m
            case .failed(let f): failure = f
            case .seekCompleted(let t): seekDone = t
            case .ended: ended = true
            default: break
            }
        }
        engine.open(startAt: 0, autoplay: true)

        func spin(until condition: () -> Bool, timeout: TimeInterval) {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        spin(until: { opened != nil || failure != nil }, timeout: 5)
        XCTAssertNil(failure)
        XCTAssertEqual(opened?.videoRenderPath, "HEVC · hardware decode")
        XCTAssertNotNil(opened?.audioRenderPath)

        spin(until: { engine.currentTime > 0.8 || failure != nil }, timeout: 6)
        XCTAssertGreaterThan(engine.currentTime, 0.8, "playback clock did not advance")
        XCTAssertNotEqual(layer.sampleBufferRenderer.status, .failed)

        engine.pause()
        engine.seek(to: 2.0, mode: .accurate)
        spin(until: { seekDone != nil }, timeout: 5)
        XCTAssertEqual(seekDone ?? -1, 2.0, accuracy: 0.001)
        spin(until: { abs(engine.currentTime - 2.0) < 0.01 }, timeout: 2)
        XCTAssertEqual(engine.currentTime, 2.0, accuracy: 0.05)

        engine.play()
        spin(until: { ended || failure != nil }, timeout: 6)
        XCTAssertTrue(ended, "never reached the end")
        XCTAssertNil(failure)
        engine.close()
    }
}
