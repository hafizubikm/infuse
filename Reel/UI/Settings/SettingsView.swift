import SwiftUI

/// Reel › Settings… (⌘,)
struct SettingsView: View {
    var body: some View {
        TabView {
            AudioSettingsView()
                .tabItem { Label("Audio", systemImage: "headphones") }
            SubtitleSettingsView()
                .tabItem { Label("Subtitles", systemImage: "captions.bubble") }
        }
        .frame(width: 500)
        .padding(20)
    }
}

struct SubtitleSettingsView: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                LabeledContent("Size") {
                    HStack {
                        Slider(value: $settings.subtitleScale, in: 0.5...2.0, step: 0.05)
                        Text("\(Int((settings.subtitleScale * 100).rounded()))%")
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("Background", selection: $settings.subtitleBackground) {
                    ForEach(AppSettings.SubtitleBackground.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Raise from bottom") {
                    HStack {
                        Slider(value: $settings.subtitleBottomOffset, in: 0...0.25, step: 0.01)
                        Text("\(Int((settings.subtitleBottomOffset * 100).rounded()))%")
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            } footer: {
                Text("Applies to text subtitles (SRT, ASS, mov_text, WebVTT). Bitmap subtitles (PGS, VobSub) are shown as authored. Subtitles are drawn at SDR white above HDR and Dolby Vision video.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Reset to defaults") {
                    settings.subtitleScale = 1
                    settings.subtitleBackground = .none
                    settings.subtitleBottomOffset = 0
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AudioSettingsView: View {
    @Bindable private var settings = AppSettings.shared
    private let monitor = AudioOutputMonitor.shared

    var body: some View {
        Form {
            Section {
                Picker("Sound", selection: $settings.audioMode) {
                    ForEach(AudioMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(settings.audioMode.explanation)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Output") {
                if let device = monitor.device {
                    LabeledContent("Device", value: "\(device.name) · \(device.transportLabel)")
                    LabeledContent("Reel uses", value: decision(for: device))
                } else {
                    Text("No output device").foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("Add a little room ambience", isOn: $settings.virtualSurroundRoom)
            } header: {
                Text("Virtual Surround")
            } footer: {
                Text("Each surround channel is placed on a virtual speaker (centre 0°, fronts ±30°, surrounds ±110°, rears ±150°) and rendered with Apple’s HRTF; the LFE goes to both ears. Room ambience adds a light reverb that can help the sound feel less “inside your head”. TrueHD Atmos and DTS:X play their channel bed; E-AC-3 is decoded by Reel in this mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !settings.rememberedDevices.isEmpty {
                Section("Remembered headphones") {
                    ForEach(settings.rememberedDevices) { device in
                        HStack {
                            Text(device.name)
                            Spacer()
                            Text(device.virtualSurround ? "Virtual Surround" : "Apple Spatial Audio")
                                .foregroundStyle(.secondary)
                            Button("Forget") { settings.forgetDevice(device.uid) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func decision(for device: AudioOutputDevice) -> String {
        let remembered = settings.rememberedVirtualSurround(for: device.uid)
        let d = AudioRoutePolicy.decide(mode: settings.audioMode, device: device, remembered: remembered)
        if d.offerVirtualSurround { return "\(d.rendering.label) (Reel will offer Virtual Surround)" }
        return d.rendering.label
    }
}
