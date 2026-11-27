import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox
import CFFmpeg

/// How compressed packets of a video track must be rewritten before VideoToolbox sees them.
enum VideoPacketFormat: Equatable {
    /// Length-prefixed NAL units (MP4/MKV). Re-emitted only if NALs must be dropped.
    case lengthPrefixed(lengthSize: Int)
    /// Annex-B start codes (MPEG-TS): converted to 4-byte length prefixes.
    case annexB
    /// AV1 low-overhead OBU stream, passed through unchanged.
    case av1
}

/// Everything the compressed video path needs to know about a track.
struct VideoTrackFormat {
    let formatDescription: CMVideoFormatDescription
    let codec: NALUtils.Codec?          // nil for AV1
    let codecType: CMVideoCodecType
    let packetFormat: VideoPacketFormat
    /// NAL unit types to strip from every packet (Dolby Vision RPU/EL when playing the base layer).
    let droppedNALTypes: Set<UInt8>
    /// Size the picture should be displayed at (pixel aspect ratio applied).
    let displaySize: CGSize
    /// Human-readable description of what is being rendered, for the info overlay.
    let renderDescription: String
}

enum VideoFormatError: Error, CustomStringConvertible {
    case unsupportedCodec(String)
    case missingParameterSets
    case coreMedia(OSStatus)

    var description: String {
        switch self {
        case .unsupportedCodec(let c): return "\(c) is not decoded by the hardware path"
        case .missingParameterSets: return "The video stream has no decoder configuration"
        case .coreMedia(let s): return "CoreMedia rejected the video format (\(s))"
        }
    }
}

/// Builds CMVideoFormatDescriptions for the hardware (compressed) path from FFmpeg stream info.
enum VideoFormatFactory {
    /// Codecs the compressed path handles. Everything else goes to the decoded path.
    static func supportsCompressedPath(codecID: AVCodecID) -> Bool {
        codecID == AV_CODEC_ID_H264 || codecID == AV_CODEC_ID_HEVC || codecID == AV_CODEC_ID_AV1
    }

    static func make(stream: UnsafeMutablePointer<AVStream>, details: VideoDetails) throws -> VideoTrackFormat {
        let par = stream.pointee.codecpar.pointee
        let extradata = par.extradata.map { UnsafeRawBufferPointer(start: $0, count: Int(par.extradata_size)) }
            ?? UnsafeRawBufferPointer(start: nil, count: 0)
        let width = Int32(par.width), height = Int32(par.height)
        let extensions = baseExtensions(details: details)

        switch par.codec_id {
        case AV_CODEC_ID_H264:
            if let lengthSize = NALUtils.lengthSize(decoderConfigurationRecord: extradata, codec: .h264) {
                let fd = try create(kCMVideoCodecType_H264, width, height, extensions, atoms: ["avcC": Data(extradata)])
                return track(fd, .h264, kCMVideoCodecType_H264, .lengthPrefixed(lengthSize: lengthSize), details, "H.264")
            }
            let fd = try fromParameterSets(NALUtils.parameterSets(annexB: extradata, codec: .h264), codec: .h264, extensions: extensions)
            return track(fd, .h264, kCMVideoCodecType_H264, .annexB, details, "H.264")

        case AV_CODEC_ID_HEVC:
            if let lengthSize = NALUtils.lengthSize(decoderConfigurationRecord: extradata, codec: .hevc) {
                let fd = try create(kCMVideoCodecType_HEVC, width, height, extensions, atoms: ["hvcC": Data(extradata)])
                return track(fd, .hevc, kCMVideoCodecType_HEVC, .lengthPrefixed(lengthSize: lengthSize), details, "HEVC")
            }
            let fd = try fromParameterSets(NALUtils.parameterSets(annexB: extradata, codec: .hevc), codec: .hevc, extensions: extensions)
            return track(fd, .hevc, kCMVideoCodecType_HEVC, .annexB, details, "HEVC")

        case AV_CODEC_ID_AV1:
            // MP4/MKV/WebM store an AV1CodecConfigurationRecord (marker bit + version 1 → 0x81).
            guard extradata.count >= 4, extradata[0] == 0x81 else { throw VideoFormatError.missingParameterSets }
            let fd = try create(kCMVideoCodecType_AV1, width, height, extensions, atoms: ["av1C": Data(extradata)])
            return track(fd, nil, kCMVideoCodecType_AV1, .av1, details, "AV1")

        default:
            throw VideoFormatError.unsupportedCodec(ffString(avcodec_get_name(par.codec_id)) ?? "?")
        }
    }

    /// Builds a format description from raw parameter sets (e.g. an in-band SPS change in MPEG-TS).
    static func fromParameterSets(_ sets: [[UInt8]], codec: NALUtils.Codec, extensions: [CFString: Any]) throws -> CMVideoFormatDescription {
        let needed = codec == .h264 ? 2 : 3
        guard sets.count >= needed else { throw VideoFormatError.missingParameterSets }
        var fd: CMVideoFormatDescription?
        let status: OSStatus = withPointers(sets) { pointers, sizes in
            switch codec {
            case .h264:
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            case .hevc:
                return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, extensions: extensions as CFDictionary, formatDescriptionOut: &fd)
            }
        }
        guard status == noErr, let fd else { throw VideoFormatError.coreMedia(status) }
        return fd
    }

    // MARK: - Extensions

    /// Colour, HDR10 static metadata and pixel aspect ratio extensions.
    static func baseExtensions(details v: VideoDetails) -> [CFString: Any] {
        var ext: [CFString: Any] = [:]
        if let p = cfString(CVColorPrimariesGetStringForIntegerCodePoint(Int32(v.color.primaries))) {
            ext[kCMFormatDescriptionExtension_ColorPrimaries] = p
        }
        if let t = cfString(CVTransferFunctionGetStringForIntegerCodePoint(Int32(v.color.transfer))) {
            ext[kCMFormatDescriptionExtension_TransferFunction] = t
        }
        if let m = cfString(CVYCbCrMatrixGetStringForIntegerCodePoint(Int32(v.color.matrix))) {
            ext[kCMFormatDescriptionExtension_YCbCrMatrix] = m
        }
        if v.color.fullRange {
            ext[kCMFormatDescriptionExtension_FullRangeVideo] = kCFBooleanTrue
        }
        if let md = v.masteringDisplay, let data = HDRMetadata.masteringDisplayColorVolume(md) {
            ext[kCMFormatDescriptionExtension_MasteringDisplayColorVolume] = data as CFData
        }
        if let cll = v.contentLightLevel, cll.maxCLL > 0 || cll.maxFALL > 0 {
            ext[kCMFormatDescriptionExtension_ContentLightLevelInfo] = HDRMetadata.contentLightLevelInfo(cll) as CFData
        }
        if let sar = v.sampleAspectRatio, sar > 0, abs(sar - 1) > 0.001 {
            let (h, vv) = rational(sar)
            ext[kCMFormatDescriptionExtension_PixelAspectRatio] = [
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: h,
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: vv,
            ] as CFDictionary
        }
        if let depth = v.bitDepth, depth > 8 {
            ext[kCMFormatDescriptionExtension_BitsPerComponent] = depth
        }
        return ext
    }

    static func create(_ codecType: CMVideoCodecType, _ width: Int32, _ height: Int32,
                       _ extensions: [CFString: Any], atoms: [String: Data]) throws -> CMVideoFormatDescription {
        var ext = extensions
        var atomDict: [CFString: CFData] = [:]
        for (k, v) in atoms { atomDict[k as CFString] = v as CFData }
        ext[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = atomDict as CFDictionary
        var fd: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: codecType, width: width, height: height,
            extensions: ext as CFDictionary, formatDescriptionOut: &fd)
        guard status == noErr, let fd else { throw VideoFormatError.coreMedia(status) }
        return fd
    }

    private static func track(_ fd: CMVideoFormatDescription, _ codec: NALUtils.Codec?, _ type: CMVideoCodecType,
                              _ format: VideoPacketFormat, _ v: VideoDetails, _ name: String,
                              dropped: Set<UInt8> = []) -> VideoTrackFormat {
        VideoTrackFormat(formatDescription: fd, codec: codec, codecType: type, packetFormat: format,
                         droppedNALTypes: dropped, displaySize: displaySize(v), renderDescription: name)
    }

    static func displaySize(_ v: VideoDetails) -> CGSize {
        let sar = v.sampleAspectRatio ?? 1
        return CGSize(width: (Double(v.width) * (sar > 0 ? sar : 1)).rounded(), height: Double(v.height))
    }

    private static func rational(_ x: Double) -> (Int, Int) {
        let den = 10000
        var num = Int((x * Double(den)).rounded()), d = den
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let g = gcd(num, d)
        num /= g; d /= g
        return (num, d)
    }

    private static func withPointers<R>(_ sets: [[UInt8]],
                                        _ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            p.initialize(from: set, count: set.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        return pointers.withUnsafeBufferPointer { pp in
            sizes.withUnsafeBufferPointer { sp in body(pp.baseAddress!, sp.baseAddress!) }
        }
    }
}

// CoreVideo's *GetStringForIntegerCodePoint functions may be imported as returning either
// CFString? or Unmanaged<CFString>? depending on the SDK; accept both.
@inline(__always) func cfString(_ value: Unmanaged<CFString>?) -> CFString? { value?.takeUnretainedValue() }
@inline(__always) func cfString(_ value: CFString?) -> CFString? { value }
