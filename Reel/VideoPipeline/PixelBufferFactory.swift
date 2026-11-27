import Foundation
import CoreMedia
import CoreVideo
import CFFmpeg

/// Turns decoded AVFrames into IOSurface-backed CVPixelBuffers (NV12, or P010 for > 8-bit)
/// with colour and HDR attachments, so AVSampleBufferDisplayLayer tone-maps them like
/// hardware-decoded video.
final class PixelBufferFactory {
    private let details: VideoDetails
    private var pool: CVPixelBufferPool?
    private var poolKey: (width: Int32, height: Int32, format: OSType)?
    private var sws: OpaquePointer?
    private var swsKey: (src: Int32, width: Int32, height: Int32, dst: Int32)?
    private var formatDescription: CMVideoFormatDescription?

    init(details: VideoDetails) {
        self.details = details
    }

    deinit { sws_freeContext(sws) }

    /// CMSampleBuffer for a decoded frame at `pts` lasting `duration`.
    func sampleBuffer(for frame: UnsafeMutablePointer<AVFrame>, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        guard let pixelBuffer = pixelBuffer(for: frame) else { return nil }
        attachColour(to: pixelBuffer, frame: frame)
        if formatDescription == nil || !CMVideoFormatDescriptionMatchesImageBuffer(formatDescription!, imageBuffer: pixelBuffer) {
            var fd: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                         formatDescriptionOut: &fd)
            formatDescription = fd
        }
        guard let fd = formatDescription else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                 formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &sb)
        return sb
    }

    // MARK: - Pixel buffers

    private func pixelBuffer(for frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let f = frame.pointee
        if f.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue, let raw = f.data.3 {
            return Unmanaged<CVPixelBuffer>.fromOpaque(raw).takeUnretainedValue()
        }
        let srcFormat = AVPixelFormat(rawValue: f.format)
        let depth = av_pix_fmt_desc_get(srcFormat).map { Int($0.pointee.comp.0.depth) } ?? 8
        let fullRange = f.color_range == AVCOL_RANGE_JPEG || isJPEGFormat(srcFormat)
        let (cvFormat, dstFormat): (OSType, AVPixelFormat) = depth > 8
            ? (fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, AV_PIX_FMT_P010LE)
            : (fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, AV_PIX_FMT_NV12)

        guard let buffer = makeBuffer(width: f.width, height: f.height, format: cvFormat) else { return nil }
        guard prepareScaler(src: srcFormat, width: f.width, height: f.height, dst: dstFormat) else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        var dstPlanes: [UnsafeMutablePointer<UInt8>?] = [
            CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self),
            CVPixelBufferGetBaseAddressOfPlane(buffer, 1)?.assumingMemoryBound(to: UInt8.self),
            nil, nil,
        ]
        var dstStrides: [Int32] = [Int32(CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)),
                                   Int32(CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)), 0, 0]
        var srcStrides = withUnsafeBytes(of: f.linesize) { Array($0.bindMemory(to: Int32.self)) }
        var srcPlanes: [UnsafePointer<UInt8>?] = withUnsafeBytes(of: f.data) {
            $0.bindMemory(to: UnsafeMutablePointer<UInt8>?.self).map { UnsafePointer($0) }
        }
        let rows = sws_scale(sws, &srcPlanes, &srcStrides, 0, f.height, &dstPlanes, &dstStrides)
        return rows > 0 ? buffer : nil
    }

    private func makeBuffer(width: Int32, height: Int32, format: OSType) -> CVPixelBuffer? {
        if pool == nil || poolKey?.width != width || poolKey?.height != height || poolKey?.format != format {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferWidthKey: Int(width),
                kCVPixelBufferHeightKey: Int(height),
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &newPool)
            pool = newPool
            poolKey = (width, height, format)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    private func prepareScaler(src: AVPixelFormat, width: Int32, height: Int32, dst: AVPixelFormat) -> Bool {
        if let k = swsKey, sws != nil, k.src == src.rawValue, k.width == width, k.height == height, k.dst == dst.rawValue {
            return true
        }
        sws_freeContext(sws)
        sws = sws_getContext(width, height, src, width, height, dst, Int32(SWS_BILINEAR), nil, nil, nil)
        swsKey = (src.rawValue, width, height, dst.rawValue)
        if sws == nil { Log.video.error("swscale can't convert \(ffString(av_get_pix_fmt_name(src)) ?? "?", privacy: .public)") }
        return sws != nil
    }

    private func isJPEGFormat(_ f: AVPixelFormat) -> Bool {
        f == AV_PIX_FMT_YUVJ420P || f == AV_PIX_FMT_YUVJ422P || f == AV_PIX_FMT_YUVJ444P
    }

    // MARK: - Colour

    private func attachColour(to buffer: CVPixelBuffer, frame: UnsafeMutablePointer<AVFrame>) {
        let f = frame.pointee
        func set(_ key: CFString, _ value: CFTypeRef?) {
            guard let value else { return }
            CVBufferSetAttachment(buffer, key, value, .shouldPropagate)
        }
        // Frame values first, container/stream values as fallback.
        let primaries = f.color_primaries != AVCOL_PRI_UNSPECIFIED ? Int(f.color_primaries.rawValue) : details.color.primaries
        let transfer = f.color_trc != AVCOL_TRC_UNSPECIFIED ? Int(f.color_trc.rawValue) : details.color.transfer
        var matrix = f.colorspace != AVCOL_SPC_UNSPECIFIED ? Int(f.colorspace.rawValue) : details.color.matrix
        if matrix == 2 { matrix = f.height <= 576 ? 6 : 1 }   // unspecified: BT.601 for SD, BT.709 for HD
        set(kCVImageBufferColorPrimariesKey, cfString(CVColorPrimariesGetStringForIntegerCodePoint(Int32(primaries))))
        set(kCVImageBufferTransferFunctionKey, cfString(CVTransferFunctionGetStringForIntegerCodePoint(Int32(transfer))))
        set(kCVImageBufferYCbCrMatrixKey, cfString(CVYCbCrMatrixGetStringForIntegerCodePoint(Int32(matrix))))

        if let md = masteringDisplay(frame) ?? details.masteringDisplay,
           let data = HDRMetadata.masteringDisplayColorVolume(md) {
            set(kCVImageBufferMasteringDisplayColorVolumeKey, data as CFData)
        }
        if let cll = contentLight(frame) ?? details.contentLightLevel, cll.maxCLL > 0 || cll.maxFALL > 0 {
            set(kCVImageBufferContentLightLevelInfoKey, HDRMetadata.contentLightLevelInfo(cll) as CFData)
        }
        let sar = f.sample_aspect_ratio
        if sar.num > 0, sar.den > 0, sar.num != sar.den {
            set(kCVImageBufferPixelAspectRatioKey, [
                kCVImageBufferPixelAspectRatioHorizontalSpacingKey: Int(sar.num),
                kCVImageBufferPixelAspectRatioVerticalSpacingKey: Int(sar.den),
            ] as CFDictionary)
        }
    }

    private func masteringDisplay(_ frame: UnsafeMutablePointer<AVFrame>) -> MasteringDisplay? {
        guard let sd = av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA),
              Int(sd.pointee.size) >= MemoryLayout<AVMasteringDisplayMetadata>.size else { return nil }
        let md = UnsafeRawPointer(sd.pointee.data).loadUnaligned(as: AVMasteringDisplayMetadata.self)
        guard md.has_primaries != 0, md.has_luminance != 0 else { return nil }
        let p = md.display_primaries
        return MasteringDisplay(
            red: ChromaticityPoint(x: p.0.0.doubleValue, y: p.0.1.doubleValue),
            green: ChromaticityPoint(x: p.1.0.doubleValue, y: p.1.1.doubleValue),
            blue: ChromaticityPoint(x: p.2.0.doubleValue, y: p.2.1.doubleValue),
            whitePoint: ChromaticityPoint(x: md.white_point.0.doubleValue, y: md.white_point.1.doubleValue),
            minLuminance: md.min_luminance.doubleValue, maxLuminance: md.max_luminance.doubleValue)
    }

    private func contentLight(_ frame: UnsafeMutablePointer<AVFrame>) -> ContentLightLevel? {
        guard let sd = av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL),
              Int(sd.pointee.size) >= MemoryLayout<AVContentLightMetadata>.size else { return nil }
        let c = UnsafeRawPointer(sd.pointee.data).loadUnaligned(as: AVContentLightMetadata.self)
        return ContentLightLevel(maxCLL: Int(c.MaxCLL), maxFALL: Int(c.MaxFALL))
    }
}
