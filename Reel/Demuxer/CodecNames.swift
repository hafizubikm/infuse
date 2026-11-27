import Foundation

/// Friendly display names for FFmpeg codec and container short names.
enum CodecNames {
    static func displayName(codec: String) -> String {
        switch codec {
        // Video
        case "h264": return "H.264"
        case "hevc": return "HEVC"
        case "av1": return "AV1"
        case "vp9": return "VP9"
        case "vp8": return "VP8"
        case "mpeg2video": return "MPEG-2"
        case "mpeg1video": return "MPEG-1"
        case "mpeg4": return "MPEG-4"
        case "msmpeg4v3": return "DivX 3"
        case "vc1", "wmv3": return "VC-1"
        case "prores": return "ProRes"
        case "mjpeg": return "MJPEG"
        // Audio
        case "aac": return "AAC"
        case "ac3": return "AC-3"
        case "eac3": return "E-AC-3"
        case "truehd": return "TrueHD"
        case "mlp": return "MLP"
        case "dts": return "DTS"
        case "flac": return "FLAC"
        case "alac": return "ALAC"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case "mp3": return "MP3"
        case "mp2": return "MP2"
        case let c where c.hasPrefix("pcm_"): return "PCM"
        // Subtitles
        case "subrip", "srt": return "SRT"
        case "ass", "ssa": return "ASS"
        case "mov_text": return "TX3G"
        case "webvtt": return "WebVTT"
        case "hdmv_pgs_subtitle": return "PGS"
        case "dvd_subtitle": return "VobSub"
        case "dvb_subtitle": return "DVB"
        default: return codec.uppercased()
        }
    }

    static func isBitmapSubtitle(codec: String) -> Bool {
        ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub"].contains(codec)
    }

    static func containerDisplayName(formatName: String, fileExtension: String) -> String {
        let ext = fileExtension.lowercased()
        switch formatName {
        case "matroska,webm": return ext == "webm" ? "WebM" : "Matroska"
        case "mov,mp4,m4a,3gp,3g2,mj2":
            switch ext {
            case "mov": return "QuickTime"
            case "m4v": return "M4V"
            default: return "MP4"
            }
        case "mpegts": return ext == "m2ts" || ext == "mts" ? "M2TS" : "MPEG-TS"
        case "avi": return "AVI"
        case "mpeg": return "MPEG-PS"
        case "flv": return "FLV"
        case "asf": return "ASF/WMV"
        case "ogg": return "Ogg"
        default: return formatName.uppercased()
        }
    }
}
