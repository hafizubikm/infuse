import Foundation

/// Human-readable labels for streams, as used by track menus and the info overlay,
/// e.g. "English · E-AC-3 5.1 Atmos" or "Japanese · PGS (Forced)".
enum TrackLabels {
    /// Format part of an audio label: "E-AC-3 5.1 Atmos", "TrueHD 7.1 Atmos", "DTS-HD MA 5.1".
    static func audioFormat(_ s: StreamInfo) -> String {
        var name = s.codecDisplayName
        if s.codecName == "dts", let profile = s.profileName {
            // FFmpeg profile names: "DTS", "DTS-ES", "DTS 96/24", "DTS-HD HRA", "DTS-HD MA", "DTS-HD MA + DTS:X", "DTS Express"
            name = profile.replacingOccurrences(of: " + DTS:X", with: "")
        }
        if s.codecName == "aac", let profile = s.profileName, profile.hasPrefix("HE-AAC") {
            name = profile
        }
        var parts = [name]
        if let a = s.audio {
            parts.append(a.channelsDescription)
            if a.isAtmos { parts.append("Atmos") }
            if a.isDTSX { parts.append("DTS:X") }
        }
        return parts.joined(separator: " ")
    }

    static func subtitleFormat(_ s: StreamInfo) -> String {
        var label = s.codecDisplayName
        var flags: [String] = []
        if s.isForced { flags.append("Forced") }
        if s.isHearingImpaired { flags.append("SDH") }
        if !flags.isEmpty { label += " (\(flags.joined(separator: ", ")))" }
        return label
    }

    /// "HEVC Main 10 · 3840×2160 · 23.976 fps · 10-bit · Dolby Vision 8.1"
    static func videoSummary(_ s: StreamInfo) -> String {
        var parts = [s.codecDisplayName + (s.profileName.map { " \($0)" } ?? "")]
        if let v = s.video {
            parts.append(Formatting.resolution(width: v.width, height: v.height))
            if let fps = Formatting.frameRate(v.frameRate) { parts.append(fps) }
            if let depth = v.bitDepth { parts.append("\(depth)-bit") }
            if let hdr = hdrDescription(v) { parts.append(hdr) }
        }
        return parts.joined(separator: " · ")
    }

    /// "Dolby Vision 8.1", "HDR10", "HLG"; nil for SDR.
    static func hdrDescription(_ v: VideoDetails) -> String? {
        switch v.hdr {
        case .sdr: return nil
        case .hdr10: return "HDR10"
        case .hlg: return "HLG"
        case .dolbyVision:
            guard let dv = v.dolbyVision else { return "Dolby Vision" }
            return "Dolby Vision \(dv.profileString)"
        }
    }

    /// Full label for a menu item: language first, then format, then the track title if useful.
    static func menuTitle(_ s: StreamInfo) -> String {
        var parts: [String] = []
        if let lang = Formatting.language(s.language) { parts.append(lang) }
        switch s.kind {
        case .audio: parts.append(audioFormat(s))
        case .subtitle: parts.append(subtitleFormat(s))
        case .video: parts.append(videoSummary(s))
        default: parts.append(s.codecDisplayName)
        }
        if let title = s.title, !title.isEmpty, !parts.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
            parts.append(title)
        }
        if parts.isEmpty { parts.append("Track \(s.index + 1)") }
        return parts.joined(separator: " · ")
    }
}
