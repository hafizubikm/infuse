import Foundation
import Observation

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    enum SubtitleBackground: String, CaseIterable, Identifiable {
        case none, translucent, opaque
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return "None (outline only)"
            case .translucent: return "Translucent box"
            case .opaque: return "Solid box"
            }
        }
    }

    /// Multiplies subtitle text size (0.5 … 2.0).
    var subtitleScale: Double {
        didSet { defaults.set(subtitleScale, forKey: Keys.subtitleScale) }
    }
    var subtitleBackground: SubtitleBackground {
        didSet { defaults.set(subtitleBackground.rawValue, forKey: Keys.subtitleBackground) }
    }
    /// Extra distance from the bottom of the picture, as a fraction of its height.
    var subtitleBottomOffset: Double {
        didSet { defaults.set(subtitleBottomOffset, forKey: Keys.subtitleBottomOffset) }
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let subtitleScale = "subtitles.scale"
        static let subtitleBackground = "subtitles.background"
        static let subtitleBottomOffset = "subtitles.bottomOffset"
    }

    private init() {
        let d = UserDefaults.standard
        subtitleScale = d.object(forKey: Keys.subtitleScale) as? Double ?? 1.0
        subtitleBackground = SubtitleBackground(rawValue: d.string(forKey: Keys.subtitleBackground) ?? "") ?? .none
        subtitleBottomOffset = d.object(forKey: Keys.subtitleBottomOffset) as? Double ?? 0.0
    }

    var subtitleStyle: SubtitleRenderer.Style {
        SubtitleRenderer.Style(scale: subtitleScale, background: subtitleBackground, bottomOffset: subtitleBottomOffset)
    }
}
