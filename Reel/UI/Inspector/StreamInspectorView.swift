import SwiftUI

/// "Get Info" sheet: what FFmpeg found in a file.
struct StreamInspectorSheet: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch model.inspector {
                case .loading(let url)?:
                    ProgressView("Reading \(url.lastPathComponent)…").frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let url, let message)?:
                    ContentUnavailableView {
                        Label("Can't read \(url.lastPathComponent)", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message).textSelection(.enabled)
                    }
                case .loaded(let info)?:
                    MediaInfoList(info: info)
                case nil:
                    EmptyView()
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { model.inspector = nil }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 520)
    }
}

struct MediaInfoList: View {
    let info: MediaInfo

    var body: some View {
        List {
            Section {
                row("Container", info.containerDisplayName)
                row("Duration", Formatting.time(info.duration))
                if let size = Formatting.fileSize(info.fileSize) { row("Size", size) }
                if let br = Formatting.bitRate(info.bitRate) { row("Bitrate", br) }
                if !info.badges.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(info.badges, id: \.self) { BadgeView(text: $0) }
                    }
                }
            } header: {
                Text(info.url.lastPathComponent).font(.headline).textCase(nil)
            }

            ForEach(info.streams) { stream in
                Section("#\(stream.index) \(stream.kind.rawValue.capitalized)") {
                    StreamRows(stream: stream)
                }
            }
        }
        .textSelection(.enabled)
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value)
    }
}

private struct StreamRows: View {
    let stream: StreamInfo

    var body: some View {
        LabeledContent("Track", value: TrackLabels.menuTitle(stream))
        LabeledContent("Codec", value: "\(stream.codecDisplayName) (\(stream.codecName))" + (stream.profileName.map { " · \($0)" } ?? ""))
        if let br = Formatting.bitRate(stream.bitRate) { LabeledContent("Bitrate", value: br) }
        let flags = [stream.isDefault ? "default" : nil, stream.isForced ? "forced" : nil,
                     stream.isHearingImpaired ? "SDH" : nil, stream.isAttachedPicture ? "cover art" : nil].compactMap { $0 }
        if !flags.isEmpty { LabeledContent("Flags", value: flags.joined(separator: ", ")) }

        if let v = stream.video {
            LabeledContent("Resolution", value: Formatting.resolution(width: v.width, height: v.height))
            if let fps = Formatting.frameRate(v.frameRate) { LabeledContent("Frame rate", value: fps) }
            LabeledContent("Pixel format", value: [v.pixelFormat, v.bitDepth.map { "\($0)-bit" }].compactMap { $0 }.joined(separator: " · "))
            LabeledContent("Colour", value: "primaries \(v.color.primaries) · transfer \(v.color.transfer) · matrix \(v.color.matrix)" + (v.color.fullRange ? " · full range" : ""))
            LabeledContent("HDR", value: TrackLabels.hdrDescription(v) ?? "SDR")
            if let dv = v.dolbyVision {
                LabeledContent("Dolby Vision", value: "Profile \(dv.profileString), level \(dv.level), RPU \(dv.rpuPresent ? "yes" : "no"), EL \(dv.elPresent ? "yes" : "no"), BL \(dv.blPresent ? "yes" : "no")")
            }
            if let md = v.masteringDisplay, let maxL = md.maxLuminance {
                LabeledContent("Mastering", value: String(format: "%.4g–%.0f nits", md.minLuminance ?? 0, maxL))
            }
            if let cll = v.contentLightLevel {
                LabeledContent("MaxCLL / MaxFALL", value: "\(cll.maxCLL) / \(cll.maxFALL) nits")
            }
        }
        if let a = stream.audio {
            LabeledContent("Channels", value: a.channelsDescription + (a.channelLayout.map { " (\($0))" } ?? ""))
            LabeledContent("Sample rate", value: "\(a.sampleRate) Hz")
        }
        if let sub = stream.subtitle {
            LabeledContent("Type", value: sub.isBitmap ? "Bitmap" : "Text")
        }
    }
}

struct BadgeView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
    }
}
