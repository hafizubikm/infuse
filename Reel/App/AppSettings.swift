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

    // MARK: Audio

    /// Posted (on main) when anything that decides the audio path changes: the sound mode, room
    /// ambience, a remembered headphone answer, or an offer dismissed for this session.
    static let audioRoutingDidChange = Notification.Name("ReelAudioRoutingDidChange")

    var audioMode: AudioMode {
        didSet { defaults.set(audioMode.rawValue, forKey: Keys.audioMode); audioRoutingChanged() }
    }
    /// A little room reverb in Virtual Surround (helps the sound feel outside your head).
    var virtualSurroundRoom: Bool {
        didSet { defaults.set(virtualSurroundRoom, forKey: Keys.virtualSurroundRoom); audioRoutingChanged() }
    }

    /// The answer to "Use Virtual Surround for …?" for one output device.
    struct RememberedDevice: Codable, Identifiable, Equatable {
        var uid: String
        var name: String
        var virtualSurround: Bool
        var id: String { uid }
    }

    private(set) var rememberedDevices: [RememberedDevice] {
        didSet {
            if let data = try? JSONEncoder().encode(rememberedDevices) { defaults.set(data, forKey: Keys.rememberedDevices) }
            audioRoutingChanged()
        }
    }
    /// Devices whose Virtual Surround offer was closed with ✕ (asked again next launch).
    private(set) var dismissedOffers: Set<String> = []

    func rememberedVirtualSurround(for uid: String) -> Bool? {
        rememberedDevices.first { $0.uid == uid }?.virtualSurround
    }

    func remember(_ device: AudioOutputDevice, virtualSurround: Bool) {
        var list = rememberedDevices.filter { $0.uid != device.uid }
        list.append(RememberedDevice(uid: device.uid, name: device.name, virtualSurround: virtualSurround))
        rememberedDevices = list
    }

    func forgetDevice(_ uid: String) {
        rememberedDevices.removeAll { $0.uid == uid }
    }

    func dismissOffer(for uid: String) {
        dismissedOffers.insert(uid)
        audioRoutingChanged()
    }

    private func audioRoutingChanged() {
        NotificationCenter.default.post(name: Self.audioRoutingDidChange, object: self)
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    private enum Keys {
        static let subtitleScale = "subtitles.scale"
        static let subtitleBackground = "subtitles.background"
        static let subtitleBottomOffset = "subtitles.bottomOffset"
        static let audioMode = "audio.mode"
        static let virtualSurroundRoom = "audio.virtualSurroundRoom"
        static let rememberedDevices = "audio.rememberedDevices"
    }

    private init() {
        let d = UserDefaults.standard
        subtitleScale = d.object(forKey: Keys.subtitleScale) as? Double ?? 1.0
        subtitleBackground = SubtitleBackground(rawValue: d.string(forKey: Keys.subtitleBackground) ?? "") ?? .none
        subtitleBottomOffset = d.object(forKey: Keys.subtitleBottomOffset) as? Double ?? 0.0
        audioMode = AudioMode(rawValue: d.string(forKey: Keys.audioMode) ?? "") ?? .auto
        virtualSurroundRoom = d.bool(forKey: Keys.virtualSurroundRoom)
        rememberedDevices = d.data(forKey: Keys.rememberedDevices)
            .flatMap { try? JSONDecoder().decode([RememberedDevice].self, from: $0) } ?? []
    }

    var subtitleStyle: SubtitleRenderer.Style {
        SubtitleRenderer.Style(scale: subtitleScale, background: subtitleBackground, bottomOffset: subtitleBottomOffset)
    }
}
