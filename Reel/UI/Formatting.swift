import Foundation

/// Human-readable formatting shared by the player, info overlay and library.
enum Formatting {
    /// 0:42, 12:05, 1:52:03
    static func time(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds.rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// 1 h 52 min, 42 min, 35 s
    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h) h \(m) min" }
        if m > 0 { return "\(m) min" }
        return "\(total) s"
    }

    /// 68.4 Mb/s, 640 kb/s
    static func bitRate(_ bitsPerSecond: Int?) -> String? {
        guard let bps = bitsPerSecond, bps > 0 else { return nil }
        if bps >= 1_000_000 { return String(format: "%.1f Mb/s", Double(bps) / 1_000_000) }
        return "\(bps / 1000) kb/s"
    }

    static func fileSize(_ bytes: Int64?) -> String? {
        guard let bytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// 23.976, 25, 59.94
    static func frameRate(_ fps: Double?) -> String? {
        guard let fps, fps > 0 else { return nil }
        var text = String(format: "%.3f", fps)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text + " fps"
    }

    /// "3840×2160" plus a common name where one applies.
    static func resolution(width: Int, height: Int) -> String {
        "\(width)×\(height)"
    }

    static func resolutionClass(width: Int, height: Int) -> String? {
        switch max(width, height * 16 / 9) {
        case 3800...: return "4K"
        case 2500..<3800: return "1440p"
        case 1900..<2500: return "1080p"
        case 1200..<1900: return "720p"
        case 1..<1200: return "SD"
        default: return nil
        }
    }

    /// "English", "Japanese" from ISO 639-2/639-1 codes; falls back to the raw code.
    static func language(_ code: String?) -> String? {
        guard let code, !code.isEmpty, code != "und" else { return nil }
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}
