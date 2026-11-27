import AppKit
import CoreGraphics

/// Draws the active subtitle cues into an image the size of the displayed picture.
///
/// The image goes on an ordinary (SDR) overlay layer above the video layer, so subtitles are
/// composited at SDR reference white instead of passing through HDR tone mapping — they stay
/// crisp and white over HDR10/Dolby Vision content rather than looking dimmed or grey.
enum SubtitleRenderer {
    struct Style: Equatable {
        var scale: Double = 1
        var background: AppSettings.SubtitleBackground = .none
        var bottomOffset: Double = 0
    }

    /// - Parameters:
    ///   - size: picture size in points; `pixelScale`: backing scale factor (2 on Retina).
    static func render(_ cues: [SubtitleCue], size: CGSize, pixelScale: CGFloat, style: Style) -> CGImage? {
        guard !cues.isEmpty, size.width >= 2, size.height >= 2 else { return nil }
        let pw = Int((size.width * pixelScale).rounded()), ph = Int((size.height * pixelScale).rounded())
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: pixelScale, y: pixelScale)

        for cue in cues {
            if case .bitmaps(let rects, let cw, let ch) = cue.content {
                drawBitmaps(rects, canvas: CGSize(width: max(1, cw), height: max(1, ch)), in: ctx, size: size)
            }
        }
        let textEvents = cues.flatMap { cue -> [ASSEvent] in
            if case .text(let e) = cue.content { return e } else { return [] }
        }
        if !textEvents.isEmpty {
            // Draw text with AppKit in a flipped (top-left origin) context.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            drawText(textEvents.sorted { $0.layer < $1.layer }, size: size, style: style)
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }

    // MARK: - Bitmaps (PGS / VobSub / DVB)

    private static func drawBitmaps(_ rects: [SubtitleBitmap], canvas: CGSize, in ctx: CGContext, size: CGSize) {
        let sx = size.width / canvas.width, sy = size.height / canvas.height
        for r in rects {
            guard let provider = CGDataProvider(data: Data(r.rgba) as CFData),
                  let image = CGImage(width: r.width, height: r.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: r.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { continue }
            // Canvas origin is top-left; Core Graphics is bottom-left.
            let rect = CGRect(x: CGFloat(r.x) * sx, y: size.height - CGFloat(r.y + r.height) * sy,
                              width: CGFloat(r.width) * sx, height: CGFloat(r.height) * sy)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: rect)
        }
    }

    // MARK: - Text (ASS events; SRT/mov_text/WebVTT arrive converted to ASS)

    private struct Laid {
        let event: ASSEvent
        let text: NSAttributedString
        let outlineText: NSAttributedString?
        var frame: CGRect
        let padding: CGFloat
        let boxColor: NSColor?
    }

    private static func drawText(_ events: [ASSEvent], size: CGSize, style: Style) {
        var bottomCursor: CGFloat?   // y of the top of the stacked bottom block
        var topCursor: CGFloat?
        var laid: [Laid] = []
        for event in events {
            let sx = size.width / event.playResX, sy = size.height / event.playResY
            let userScale = CGFloat(style.scale)
            let maxWidth = max(40, size.width - CGFloat(event.marginL + event.marginR) * sx)
            let (text, outlineText, fontPx) = attributed(event, sy: sy, userScale: userScale)
            var bounds = text.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading])
            bounds.size.width = ceil(min(maxWidth, bounds.width))
            bounds.size.height = ceil(bounds.height)
            let pad = max(2, fontPx * 0.15)

            let h = (event.alignment - 1) % 3          // 0 left, 1 centre, 2 right
            let v = (event.alignment - 1) / 3          // 0 bottom, 1 middle, 2 top
            var origin = CGPoint.zero
            if let pos = event.position {
                let px = CGFloat(pos.x) * sx, py = CGFloat(pos.y) * sy
                origin.x = h == 0 ? px : h == 1 ? px - bounds.width / 2 : px - bounds.width
                origin.y = v == 2 ? py : v == 1 ? py - bounds.height / 2 : py - bounds.height
            } else {
                let ml = CGFloat(event.marginL) * sx, mr = CGFloat(event.marginR) * sx
                let mv = CGFloat(event.marginV) * sy
                origin.x = h == 0 ? ml : h == 1 ? (size.width - bounds.width) / 2 : size.width - mr - bounds.width
                switch v {
                case 0:
                    let bottom = (bottomCursor ?? (size.height - mv - CGFloat(style.bottomOffset) * size.height))
                    origin.y = bottom - bounds.height
                    bottomCursor = origin.y - pad
                case 2:
                    origin.y = topCursor ?? mv
                    topCursor = origin.y + bounds.height + pad
                default:
                    origin.y = (size.height - bounds.height) / 2
                }
            }
            let boxColor: NSColor?
            switch style.background {
            case .translucent: boxColor = NSColor(white: 0, alpha: 0.55)
            case .opaque: boxColor = NSColor(white: 0, alpha: 0.9)
            case .none: boxColor = event.borderStyle == 3 ? color(event.backColor) : nil
            }
            laid.append(Laid(event: event, text: text, outlineText: outlineText,
                             frame: CGRect(origin: origin, size: bounds.size), padding: pad, boxColor: boxColor))
        }

        for item in laid {
            if let box = item.boxColor {
                box.setFill()
                NSBezierPath(roundedRect: item.frame.insetBy(dx: -item.padding * 2, dy: -item.padding),
                             xRadius: item.padding * 1.5, yRadius: item.padding * 1.5).fill()
            }
            // Outline first (stroke only), then the fill on top, so the outline sits outside the glyphs.
            item.outlineText?.draw(with: item.frame, options: [.usesLineFragmentOrigin, .usesFontLeading])
            item.text.draw(with: item.frame, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    /// Fill text and (optionally) a stroke-only copy for the outline.
    private static func attributed(_ e: ASSEvent, sy: CGFloat, userScale: CGFloat)
        -> (NSAttributedString, NSAttributedString?, CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        let h = (e.alignment - 1) % 3
        paragraph.alignment = h == 0 ? .left : h == 1 ? .center : .right
        paragraph.lineBreakMode = .byWordWrapping

        let fill = NSMutableAttributedString()
        let outline = NSMutableAttributedString()
        var maxFont: CGFloat = 0
        let outlinePx = CGFloat(e.outline) * sy * userScale
        let shadowPx = CGFloat(e.shadow) * sy * userScale
        for run in e.runs {
            let px = max(6, CGFloat(run.fontSize) * sy * userScale)
            maxFont = max(maxFont, px)
            let font = makeFont(run.fontName, size: px, bold: run.bold, italic: run.italic)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color(run.color), .paragraphStyle: paragraph,
            ]
            if run.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if shadowPx > 0 {
                let shadow = NSShadow()
                shadow.shadowOffset = NSSize(width: shadowPx, height: -shadowPx)
                shadow.shadowBlurRadius = shadowPx
                shadow.shadowColor = NSColor(white: 0, alpha: 0.6)
                attrs[.shadow] = shadow
            }
            fill.append(NSAttributedString(string: run.text, attributes: attrs))
            if outlinePx > 0 {
                var o = attrs
                o[.strokeColor] = color(run.outlineColor)
                o[.strokeWidth] = outlinePx * 2 / px * 100      // percent of font size, positive = stroke only
                o[.foregroundColor] = NSColor.clear
                outline.append(NSAttributedString(string: run.text, attributes: o))
            }
        }
        return (fill, outline.length > 0 ? outline : nil, maxFont)
    }

    private static func makeFont(_ name: String, size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        var font = NSFont(name: name, size: size)
            ?? NSFont(name: "Helvetica Neue", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .medium)
        let manager = NSFontManager.shared
        if bold { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    private static func color(_ c: SubtitleColor) -> NSColor {
        NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }
}
