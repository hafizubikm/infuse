import AppKit
import QuartzCore

/// The overlay layer that shows subtitles above the video layer, positioned on the
/// aspect-fit picture rectangle. Re-renders only when the visible cues or the size change.
final class SubtitleLayer: CALayer {
    private var shownCues: [SubtitleCue] = []
    private var shownSize: CGSize = .zero
    private var shownStyle = SubtitleRenderer.Style()

    override init() {
        super.init()
        contentsGravity = .resize
        isOpaque = false
        actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
    }

    override init(layer: Any) { super.init(layer: layer) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Lays the layer over the picture area of a `videoSize` video shown aspect-fit in `bounds`.
    func layout(in bounds: CGRect, videoSize: CGSize?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let v = videoSize, v.width > 0, v.height > 0 {
            let scale = min(bounds.width / v.width, bounds.height / v.height)
            let w = v.width * scale, h = v.height * scale
            frame = CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h).integral
        } else {
            frame = bounds
        }
        CATransaction.commit()
    }

    /// Shows `cues` (called every display refresh; cheap when nothing changed).
    func show(_ cues: [SubtitleCue], style: SubtitleRenderer.Style) {
        let size = bounds.size
        guard cues != shownCues || size != shownSize || style != shownStyle else { return }
        shownCues = cues
        shownSize = size
        shownStyle = style
        let image = SubtitleRenderer.render(cues, size: size, pixelScale: contentsScale, style: style)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contents = image
        CATransaction.commit()
    }
}
