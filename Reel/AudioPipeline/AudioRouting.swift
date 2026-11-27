import Foundation

/// The Sound setting (Settings › Audio, and the player's audio menu).
enum AudioMode: String, CaseIterable, Identifiable, Sendable {
    /// Apple Spatial Audio for AirPods, Beats and the Mac's speakers; for other headphones Reel
    /// offers Virtual Surround once and remembers the answer per device.
    case auto
    case spatial
    case virtualSurround
    case stereo

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .spatial: return "Apple Spatial Audio"
        case .virtualSurround: return "Virtual Surround"
        case .stereo: return "Stereo"
        }
    }

    var explanation: String {
        switch self {
        case .auto:
            return "AirPods, Beats and the Mac’s speakers get Apple Spatial Audio. For other headphones Reel offers Virtual Surround and remembers your answer for each device."
        case .spatial:
            return "Multichannel and Atmos audio go to macOS, which spatializes them for AirPods and Beats (with head tracking) and the built-in speakers, and passes them on to receivers and other outputs."
        case .virtualSurround:
            return "Reel places each 5.1/7.1 channel on a virtual speaker around you and renders it for headphones with Apple’s HRTF. Works with any headphones. Stereo sources play unchanged."
        case .stereo:
            return "Plain two-channel downmix with no spatial processing."
        }
    }
}

/// How the sound is actually produced.
enum AudioRendering: String, Sendable {
    /// Multichannel / Atmos handed to macOS, which spatializes it where it can.
    case spatial
    /// Reel's binaural virtualizer (virtual speakers + HRTF) → stereo.
    case virtualSurround
    /// Plain stereo downmix.
    case stereo

    var label: String {
        switch self {
        case .spatial: return "Apple Spatial Audio"
        case .virtualSurround: return "Virtual Surround"
        case .stereo: return "Stereo"
        }
    }
}

/// The system's default output device, as Reel classifies it.
struct AudioOutputDevice: Equatable, Sendable {
    enum Transport: String, Sendable {
        case builtIn, bluetooth, bluetoothLE, usb, hdmi, displayPort, airPlay, thunderbolt, aggregate, virtual, other
    }

    enum Kind: Equatable, Sendable {
        /// AirPods / Beats: macOS does head-tracked Spatial Audio itself.
        case appleHeadphones
        /// Other Bluetooth headphones, the headphone jack, USB headsets: candidates for Virtual Surround.
        case otherHeadphones
        /// The Mac's speakers (spatialized by macOS on recent MacBooks).
        case builtInSpeakers
        /// Receivers, TVs, AirPlay, audio interfaces: get the multichannel signal as-is.
        case external
    }

    /// Core Audio's persistent device UID (stable across reconnects; used to remember choices).
    var uid: String
    var name: String
    var manufacturer: String = ""
    var modelUID: String = ""
    var transport: Transport
    /// The built-in output's data source is the headphone jack.
    var isHeadphonePort: Bool = false
    var outputChannels: Int = 2

    var kind: Kind {
        switch transport {
        case .bluetooth, .bluetoothLE:
            return isAppleHeadphones ? .appleHeadphones : .otherHeadphones
        case .builtIn:
            return isHeadphonePort || nameContains("headphone") ? .otherHeadphones : .builtInSpeakers
        case .usb:
            return ["headphone", "headset", "earbud", "earphone"].contains(where: nameContains) ? .otherHeadphones : .external
        default:
            return .external
        }
    }

    /// AirPods and Beats, recognised by name or by Apple's Bluetooth vendor ID (0x004C) in the
    /// model UID. (Every Bluetooth device is created by Apple's driver, so the manufacturer
    /// string can't be trusted for this.)
    var isAppleHeadphones: Bool {
        if ["airpods", "beats", "powerbeats"].contains(where: nameContains) { return true }
        let parts = modelUID.lowercased().split(whereSeparator: { !$0.isHexDigit && $0 != "x" })
        return parts.contains { $0 == "4c" || $0 == "004c" || $0 == "0x4c" || $0 == "0x004c" }
    }

    var transportLabel: String {
        switch transport {
        case .builtIn: return isHeadphonePort ? "Headphone jack" : "Built-in"
        case .bluetooth, .bluetoothLE: return "Bluetooth"
        case .usb: return "USB"
        case .hdmi: return "HDMI"
        case .displayPort: return "DisplayPort"
        case .airPlay: return "AirPlay"
        case .thunderbolt: return "Thunderbolt"
        case .aggregate: return "Aggregate"
        case .virtual: return "Virtual"
        case .other: return "Other"
        }
    }

    private func nameContains(_ s: String) -> Bool { name.localizedCaseInsensitiveContains(s) }
}

enum AudioRoutePolicy {
    struct Decision: Equatable {
        var rendering: AudioRendering
        /// Offer "Use Virtual Surround for <device>?" (Auto, non-Apple headphones, not answered yet).
        var offerVirtualSurround: Bool
    }

    /// - Parameter remembered: the answer given for this device before (true = Virtual Surround).
    static func decide(mode: AudioMode, device: AudioOutputDevice?, remembered: Bool?) -> Decision {
        switch mode {
        case .spatial: return Decision(rendering: .spatial, offerVirtualSurround: false)
        case .virtualSurround: return Decision(rendering: .virtualSurround, offerVirtualSurround: false)
        case .stereo: return Decision(rendering: .stereo, offerVirtualSurround: false)
        case .auto:
            guard let device, device.kind == .otherHeadphones else {
                return Decision(rendering: .spatial, offerVirtualSurround: false)
            }
            if let remembered {
                return Decision(rendering: remembered ? .virtualSurround : .spatial, offerVirtualSurround: false)
            }
            return Decision(rendering: .spatial, offerVirtualSurround: true)
        }
    }
}

/// Follows output-device, setting and track changes for one player and says what to do: rebuild
/// the audio path, offer Virtual Surround, announce the new device. Free of UI and Core Audio so
/// the state machine can be tested on its own.
struct AudioRouteTracker {
    struct Inputs: Equatable {
        var mode: AudioMode
        var device: AudioOutputDevice?
        /// The remembered answer for `device` (true = Virtual Surround).
        var remembered: Bool?
        /// Channels of the audio track playing (0 = not known yet).
        var sourceChannels: Int
        /// The offer for `device` was closed with ✕ earlier in this session.
        var offerDismissed = false
    }

    enum Action: Equatable {
        /// (Re)build the audio path this way.
        case render(AudioRendering)
        /// Show the "Use Virtual Surround for …?" banner.
        case offer(AudioOutputDevice)
        case withdrawOffer
        /// Short notice after the output device changed ("Sony WH-1000XM5 · Virtual Surround").
        case announce(String)
    }

    private(set) var rendering: AudioRendering?
    private(set) var offer: AudioOutputDevice?
    private var deviceUID: String?
    private var seenDevice = false

    mutating func update(_ inputs: Inputs) -> [Action] {
        var actions: [Action] = []
        let decision = AudioRoutePolicy.decide(mode: inputs.mode, device: inputs.device, remembered: inputs.remembered)
        if decision.rendering != rendering {
            rendering = decision.rendering
            actions.append(.render(decision.rendering))
        }
        if inputs.device?.uid != deviceUID {
            if seenDevice, let device = inputs.device {
                actions.append(.announce("\(device.name) · \(decision.rendering.label)"))
            }
            deviceUID = inputs.device?.uid
        }
        if inputs.device != nil { seenDevice = true }

        let wantsOffer = decision.offerVirtualSurround && inputs.sourceChannels > 2 && !inputs.offerDismissed
        if wantsOffer, let device = inputs.device {
            if offer != device {
                offer = device
                actions.append(.offer(device))
            }
        } else if offer != nil {
            offer = nil
            actions.append(.withdrawOffer)
        }
        return actions
    }
}
