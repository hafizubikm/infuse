import SwiftUI

/// Reel › Settings… (⌘,)
struct SettingsView: View {
    var body: some View {
        TabView {
            SubtitleSettingsView()
                .tabItem { Label("Subtitles", systemImage: "captions.bubble") }
        }
        .frame(width: 460)
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
