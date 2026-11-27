import Foundation
import CFFmpeg

/// Opens a file with FFmpeg and describes it as `MediaInfo`.
enum MediaProbe {
    struct Options {
        /// Bytes FFmpeg may read to detect streams (FFmpeg's default is 5 MB).
        var probeSize: Int64 = 10_000_000
        /// Microseconds of media FFmpeg may analyse (FFmpeg's default is 5 s).
        var analyzeDuration: Int64 = 5_000_000

        static let `default` = Options()
        /// Cheaper settings for scanning a whole library.
        static let fast = Options(probeSize: 4_000_000, analyzeDuration: 2_000_000)
    }

    static func probe(url: URL, options: Options = .default) throws -> MediaInfo {
        let file = try MediaFile(url: url, options: options)
        file.detectAudioFeatures()
        return file.info
    }

    /// Builds `MediaInfo` from an opened format context (after avformat_find_stream_info).
    static func describe(_ ctx: UnsafeMutablePointer<AVFormatContext>, url: URL) -> MediaInfo {
        let fc = ctx.pointee
        let formatName = ffString(fc.iformat?.pointee.name) ?? "unknown"
        var streams: [StreamInfo] = []
        for i in 0..<Int(fc.nb_streams) {
            guard let st = fc.streams[i] else { continue }
            streams.append(describe(stream: st))
        }
        let duration = fc.duration != ffNoPTS && fc.duration > 0
            ? Double(fc.duration) / Double(AV_TIME_BASE) : nil
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
        return MediaInfo(
            url: url,
            formatName: formatName,
            containerDisplayName: CodecNames.containerDisplayName(formatName: formatName, fileExtension: url.pathExtension),
            duration: duration,
            bitRate: fc.bit_rate > 0 ? Int(fc.bit_rate) : nil,
            fileSize: fileSize,
            streams: streams
        )
    }

    static func describe(stream st: UnsafeMutablePointer<AVStream>) -> StreamInfo {
        let s = st.pointee
        let par = s.codecpar.pointee
        let codecName = ffString(avcodec_get_name(par.codec_id)) ?? "unknown"
        let kind: StreamKind
        switch par.codec_type {
        case AVMEDIA_TYPE_VIDEO: kind = .video
        case AVMEDIA_TYPE_AUDIO: kind = .audio
        case AVMEDIA_TYPE_SUBTITLE: kind = .subtitle
        case AVMEDIA_TYPE_ATTACHMENT: kind = .attachment
        case AVMEDIA_TYPE_DATA: kind = .data
        default: kind = .unknown
        }

        var info = StreamInfo(
            index: Int(s.index),
            kind: kind,
            codecName: codecName,
            codecDisplayName: CodecNames.displayName(codec: codecName),
            profileName: par.profile != AV_PROFILE_UNKNOWN ? ffString(avcodec_profile_name(par.codec_id, par.profile)) : nil,
            language: metadata(s.metadata, "language").flatMap { $0 == "und" ? nil : $0 },
            title: metadata(s.metadata, "title"),
            bitRate: par.bit_rate > 0 ? Int(par.bit_rate) : nil,
            isDefault: s.disposition & AV_DISPOSITION_DEFAULT != 0,
            isForced: s.disposition & AV_DISPOSITION_FORCED != 0,
            isHearingImpaired: s.disposition & AV_DISPOSITION_HEARING_IMPAIRED != 0,
            isAttachedPicture: s.disposition & AV_DISPOSITION_ATTACHED_PIC != 0
        )

        switch kind {
        case .video: info.video = videoDetails(st)
        case .audio: info.audio = audioDetails(st, codecName: codecName)
        case .subtitle:
            info.subtitle = SubtitleDetails(
                isBitmap: CodecNames.isBitmapSubtitle(codec: codecName),
                canvasWidth: par.width > 0 ? Int(par.width) : nil,
                canvasHeight: par.height > 0 ? Int(par.height) : nil
            )
        default: break
        }
        return info
    }

    // MARK: - Video

    private static func videoDetails(_ st: UnsafeMutablePointer<AVStream>) -> VideoDetails {
        let s = st.pointee
        let par = s.codecpar.pointee
        var v = VideoDetails(width: Int(par.width), height: Int(par.height))

        let sar = par.sample_aspect_ratio.isValid ? par.sample_aspect_ratio : s.sample_aspect_ratio
        if sar.isValid, sar.num != sar.den { v.sampleAspectRatio = sar.doubleValue }

        let rate = s.avg_frame_rate.isValid ? s.avg_frame_rate : s.r_frame_rate
        if rate.isValid { v.frameRate = rate.doubleValue }

        let pixFmt = AVPixelFormat(rawValue: par.format)
        if pixFmt != AV_PIX_FMT_NONE {
            v.pixelFormat = ffString(av_get_pix_fmt_name(pixFmt))
            if let desc = av_pix_fmt_desc_get(pixFmt) {
                v.bitDepth = Int(desc.pointee.comp.0.depth)
            }
        }
        if v.bitDepth == nil, par.bits_per_raw_sample > 0 {
            v.bitDepth = Int(par.bits_per_raw_sample)
        }

        v.color = ColorDescription(
            primaries: Int(par.color_primaries.rawValue),
            transfer: Int(par.color_trc.rawValue),
            matrix: Int(par.color_space.rawValue),
            fullRange: par.color_range == AVCOL_RANGE_JPEG
        )

        if let dovi: AVDOVIDecoderConfigurationRecord = sideData(par, AV_PKT_DATA_DOVI_CONF) {
            v.dolbyVision = DolbyVisionConfig(
                versionMajor: dovi.dv_version_major,
                versionMinor: dovi.dv_version_minor,
                profile: dovi.dv_profile,
                level: dovi.dv_level,
                rpuPresent: dovi.rpu_present_flag != 0,
                elPresent: dovi.el_present_flag != 0,
                blPresent: dovi.bl_present_flag != 0,
                blSignalCompatibilityID: dovi.dv_bl_signal_compatibility_id
            )
        }

        if let md: AVMasteringDisplayMetadata = sideData(par, AV_PKT_DATA_MASTERING_DISPLAY_METADATA) {
            var m = MasteringDisplay()
            if md.has_primaries != 0 {
                let p = md.display_primaries
                m.red = ChromaticityPoint(x: p.0.0.doubleValue, y: p.0.1.doubleValue)
                m.green = ChromaticityPoint(x: p.1.0.doubleValue, y: p.1.1.doubleValue)
                m.blue = ChromaticityPoint(x: p.2.0.doubleValue, y: p.2.1.doubleValue)
                m.whitePoint = ChromaticityPoint(x: md.white_point.0.doubleValue, y: md.white_point.1.doubleValue)
            }
            if md.has_luminance != 0 {
                m.minLuminance = md.min_luminance.doubleValue
                m.maxLuminance = md.max_luminance.doubleValue
            }
            v.masteringDisplay = m
        }

        if let cll: AVContentLightMetadata = sideData(par, AV_PKT_DATA_CONTENT_LIGHT_LEVEL) {
            v.contentLightLevel = ContentLightLevel(maxCLL: Int(cll.MaxCLL), maxFALL: Int(cll.MaxFALL))
        }

        v.hdr = classifyHDR(color: v.color, dolbyVision: v.dolbyVision)
        return v
    }

    static func classifyHDR(color: ColorDescription, dolbyVision: DolbyVisionConfig?) -> HDRFormat {
        if dolbyVision != nil { return .dolbyVision }
        if color.isPQ { return .hdr10 }
        if color.isHLG { return .hlg }
        return .sdr
    }

    // MARK: - Audio

    private static func audioDetails(_ st: UnsafeMutablePointer<AVStream>, codecName: String) -> AudioDetails {
        let par = st.pointee.codecpar.pointee
        var layout = par.ch_layout
        var buffer = [CChar](repeating: 0, count: 128)
        let layoutName = av_channel_layout_describe(&layout, &buffer, buffer.count) > 0
            ? String(cString: buffer) : nil
        var a = AudioDetails(
            sampleRate: Int(par.sample_rate),
            channels: Int(par.ch_layout.nb_channels),
            channelLayout: layoutName
        )
        switch par.codec_id {
        case AV_CODEC_ID_EAC3: a.isAtmos = par.profile == AV_PROFILE_EAC3_DDP_ATMOS
        case AV_CODEC_ID_TRUEHD: a.isAtmos = par.profile == AV_PROFILE_TRUEHD_ATMOS
        case AV_CODEC_ID_DTS: a.isDTSX = par.profile == AV_PROFILE_DTS_HD_MA_X || par.profile == AV_PROFILE_DTS_HD_MA_X_IMAX
        default: break
        }
        return a
    }

    // MARK: - Helpers

    private static func metadata(_ dict: OpaquePointer?, _ key: String) -> String? {
        guard let dict, let entry = av_dict_get(dict, key, nil, 0) else { return nil }
        return ffString(entry.pointee.value)
    }

    /// Reads a POD side-data struct of type `T` from the stream's coded side data.
    static func sideData<T>(_ par: AVCodecParameters, _ type: AVPacketSideDataType) -> T? {
        guard let sd = av_packet_side_data_get(par.coded_side_data, par.nb_coded_side_data, type),
              let data = sd.pointee.data,
              sd.pointee.size >= MemoryLayout<T>.size
        else { return nil }
        return UnsafeRawPointer(data).loadUnaligned(as: T.self)
    }

    /// Raw bytes of a side-data entry.
    static func sideDataBytes(_ par: AVCodecParameters, _ type: AVPacketSideDataType) -> Data? {
        guard let sd = av_packet_side_data_get(par.coded_side_data, par.nb_coded_side_data, type),
              let data = sd.pointee.data
        else { return nil }
        return Data(bytes: data, count: Int(sd.pointee.size))
    }
}
