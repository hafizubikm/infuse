import Foundation

// Plain-Swift description of a media file and its streams. Produced by `MediaProbe`
// from FFmpeg's AVFormatContext; consumed by the UI, the library and the pipelines.
// Deliberately free of FFmpeg/CoreMedia types so it is easy to test and persist.

enum StreamKind: String, Codable, Sendable {
    case video, audio, subtitle, attachment, data, unknown
}

/// Colour description using ITU-T H.273 code points (the same values FFmpeg uses
/// for AVColorPrimaries / AVColorTransferCharacteristic / AVColorSpace).
struct ColorDescription: Codable, Equatable, Sendable {
    var primaries: Int = 2      // 2 = unspecified
    var transfer: Int = 2
    var matrix: Int = 2
    var fullRange: Bool = false

    static let h273BT709 = 1
    static let h273BT2020Primaries = 9
    static let h273TransferPQ = 16      // SMPTE ST 2084
    static let h273TransferHLG = 18     // ARIB STD-B67
    static let h273MatrixBT2020NCL = 9

    var isPQ: Bool { transfer == Self.h273TransferPQ }
    var isHLG: Bool { transfer == Self.h273TransferHLG }
}

struct ChromaticityPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
}

/// SMPTE ST 2086 mastering display colour volume.
struct MasteringDisplay: Codable, Equatable, Sendable {
    var red: ChromaticityPoint?
    var green: ChromaticityPoint?
    var blue: ChromaticityPoint?
    var whitePoint: ChromaticityPoint?
    var minLuminance: Double?   // cd/m²
    var maxLuminance: Double?   // cd/m²
}

/// CTA-861.3 content light level.
struct ContentLightLevel: Codable, Equatable, Sendable {
    var maxCLL: Int
    var maxFALL: Int
}

/// Dolby Vision decoder configuration record (the payload of a dvcC/dvvC box).
struct DolbyVisionConfig: Codable, Equatable, Sendable {
    var versionMajor: UInt8 = 1
    var versionMinor: UInt8 = 0
    var profile: UInt8
    var level: UInt8
    var rpuPresent: Bool
    var elPresent: Bool
    var blPresent: Bool
    var blSignalCompatibilityID: UInt8

    /// "5", "7", "8.1", "8.4" …
    var profileString: String {
        switch profile {
        case 8 where blSignalCompatibilityID != 0, 10 where blSignalCompatibilityID != 0:
            return "\(profile).\(blSignalCompatibilityID)"
        default:
            return "\(profile)"
        }
    }

    /// Profile 7 is the Blu-ray dual-layer format; Reel plays its HDR10 base layer.
    var isDualLayer: Bool { profile == 7 || (elPresent && blPresent && profile != 8) }
}

enum HDRFormat: String, Codable, Sendable {
    case sdr, hdr10, hlg, dolbyVision

    var badge: String? {
        switch self {
        case .sdr: return nil
        case .hdr10: return "HDR10"
        case .hlg: return "HLG"
        case .dolbyVision: return "DV"
        }
    }
}

struct VideoDetails: Codable, Equatable, Sendable {
    var width: Int
    var height: Int
    var sampleAspectRatio: Double?      // nil or 1.0 for square pixels
    var frameRate: Double?
    var pixelFormat: String?
    var bitDepth: Int?
    var color = ColorDescription()
    var hdr: HDRFormat = .sdr
    var dolbyVision: DolbyVisionConfig?
    var masteringDisplay: MasteringDisplay?
    var contentLightLevel: ContentLightLevel?
}

struct AudioDetails: Codable, Equatable, Sendable {
    var sampleRate: Int
    var channels: Int
    var channelLayout: String?          // FFmpeg's description, e.g. "5.1(side)"
    var isAtmos: Bool = false
    var isDTSX: Bool = false

    /// "Mono", "Stereo", "5.1", "7.1" …
    var channelsDescription: String {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 3: return channelLayout?.hasPrefix("2.1") == true ? "2.1" : "3.0"
        case 6: return "5.1"
        case 7: return "6.1"
        case 8: return "7.1"
        default:
            if let channelLayout, !channelLayout.isEmpty { return channelLayout }
            return "\(channels)ch"
        }
    }
}

struct SubtitleDetails: Codable, Equatable, Sendable {
    var isBitmap: Bool
    var canvasWidth: Int?
    var canvasHeight: Int?
}

struct StreamInfo: Identifiable, Codable, Equatable, Sendable {
    var index: Int
    var kind: StreamKind
    var codecName: String           // FFmpeg short name, e.g. "hevc", "eac3"
    var codecDisplayName: String    // e.g. "HEVC", "E-AC-3"
    var profileName: String?        // e.g. "Main 10", "DTS-HD MA"
    var language: String?           // ISO 639-2 as stored in the container
    var title: String?
    var bitRate: Int?
    var isDefault = false
    var isForced = false
    var isHearingImpaired = false
    var isAttachedPicture = false
    var video: VideoDetails?
    var audio: AudioDetails?
    var subtitle: SubtitleDetails?

    var id: Int { index }
}

struct MediaInfo: Codable, Equatable, Sendable {
    var url: URL
    var formatName: String          // FFmpeg demuxer name, e.g. "matroska,webm"
    var containerDisplayName: String
    var duration: Double?           // seconds
    var bitRate: Int?
    var fileSize: Int64?
    var streams: [StreamInfo]

    var videoStreams: [StreamInfo] { streams.filter { $0.kind == .video && !$0.isAttachedPicture } }
    var audioStreams: [StreamInfo] { streams.filter { $0.kind == .audio } }
    var subtitleStreams: [StreamInfo] { streams.filter { $0.kind == .subtitle } }

    /// The stream a player would pick by default.
    var primaryVideo: StreamInfo? {
        videoStreams.first(where: \.isDefault) ?? videoStreams.first
    }

    var primaryAudio: StreamInfo? {
        audioStreams.first(where: \.isDefault) ?? audioStreams.first
    }

    /// Badges for library and info views: "DV", "HDR10", "HLG", "Atmos", "DTS:X".
    var badges: [String] {
        var result: [String] = []
        if let hdr = primaryVideo?.video?.hdr.badge { result.append(hdr) }
        if audioStreams.contains(where: { $0.audio?.isAtmos == true }) { result.append("Atmos") }
        if audioStreams.contains(where: { $0.audio?.isDTSX == true }) { result.append("DTS:X") }
        return result
    }
}
