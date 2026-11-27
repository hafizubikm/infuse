import SwiftUI

/// Technical details of what is playing (toggle with I).
struct InfoOverlay: View {
    let controller: PlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let media = controller.media {
                section("File") {
                    row("Name", media.info.url.lastPathComponent)
                    row("Container", media.info.containerDisplayName)
                    if let size = Formatting.fileSize(media.info.fileSize) { row("Size", size) }
                    if let br = Formatting.bitRate(media.info.bitRate) { row("Bitrate", br) }
                }
                if let vs = media.videoStream, let v = vs.video {
                    section("Video") {
                        row("Codec", vs.codecDisplayName + (vs.profileName.map { " \($0)" } ?? ""))
                        row("Resolution", Formatting.resolution(width: v.width, height: v.height)
                            + (media.displaySize.map { $0.width != CGFloat(v.width) ? " (shown \(Int($0.width))×\(Int($0.height)))" : "" } ?? ""))
                        if let depth = v.bitDepth { row("Bit depth", "\(depth)-bit" + (v.pixelFormat.map { " · \($0)" } ?? "")) }
                        if let fps = Formatting.frameRate(v.frameRate) { row("Frame rate", fps) }
                        row("HDR", hdrText(v))
                        if let md = v.masteringDisplay, let maxL = md.maxLuminance {
                            row("Mastering", String(format: "%.4g–%.0f nits", md.minLuminance ?? 0, maxL))
                        }
                        if let cll = v.contentLightLevel { row("MaxCLL/FALL", "\(cll.maxCLL) / \(cll.maxFALL) nits") }
                        if let br = Formatting.bitRate(vs.bitRate) { row("Bitrate", br) }
                        if let path = controller.videoRenderPath { row("Rendering", path) }
                    }
                }
                if let a = media.audioStream, let ad = a.audio {
                    section("Audio") {
                        row("Track", TrackLabels.menuTitle(a))
                        row("Format", TrackLabels.audioFormat(a) + " · \(ad.sampleRate / 1000) kHz")
                        if let layout = ad.channelLayout { row("Layout", layout) }
                        if let br = Formatting.bitRate(a.bitRate) { row("Bitrate", br) }
                        if let path = controller.audioRenderPath { row("Output", path) }
                    }
                }
            } else {
                Text("Opening…")
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
    }

    private func hdrText(_ v: VideoDetails) -> String {
        if let dv = v.dolbyVision {
            var parts = ["Dolby Vision Profile \(dv.profileString)", "level \(dv.level)"]
            if dv.elPresent { parts.append("enhancement layer") }
            switch dv.blSignalCompatibilityID {
            case 1: parts.append("HDR10-compatible")
            case 2: parts.append("SDR-compatible")
            case 4: parts.append("HLG-compatible")
            case 6: parts.append("Blu-ray HDR10-compatible")
            default: break
            }
            return parts.joined(separator: ", ")
        }
        return TrackLabels.hdrDescription(v) ?? "SDR"
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.6))
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.white.opacity(0.65)).frame(width: 96, alignment: .leading)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
    }
}
