import Foundation

/// RGBA colour with components 0…1 (ASS stores &HAABBGGRR with inverted alpha).
struct SubtitleColor: Equatable, Sendable {
    var red: Double, green: Double, blue: Double, alpha: Double

    static let white = SubtitleColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let black = SubtitleColor(red: 0, green: 0, blue: 0, alpha: 1)

    /// Parses "&H00FFFFFF", "&HFFFFFF&", "&H80000000" or a decimal value.
    init?(ass text: String) {
        var s = text.trimmingCharacters(in: .whitespaces).uppercased()
        let value: UInt32
        if s.hasPrefix("&H") || s.hasPrefix("H") {
            s = s.replacingOccurrences(of: "&H", with: "").replacingOccurrences(of: "&", with: "")
            if s.hasPrefix("H") { s.removeFirst() }
            guard let v = UInt32(s, radix: 16) else { return nil }
            value = v
        } else if let v = Int64(s) {
            value = UInt32(truncatingIfNeeded: v)
        } else {
            return nil
        }
        red = Double(value & 0xFF) / 255
        green = Double((value >> 8) & 0xFF) / 255
        blue = Double((value >> 16) & 0xFF) / 255
        alpha = 1 - Double((value >> 24) & 0xFF) / 255
    }

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
}

struct ASSStyle: Equatable, Sendable {
    var name = "Default"
    var fontName = "Helvetica Neue"
    var fontSize: Double = 18
    var primary = SubtitleColor.white
    var outlineColor = SubtitleColor.black
    var backColor = SubtitleColor(red: 0, green: 0, blue: 0, alpha: 0.5)
    var bold = false
    var italic = false
    var underline = false
    /// 1 = outline + shadow, 3 = opaque box.
    var borderStyle = 1
    var outline: Double = 2
    var shadow: Double = 0
    /// Numpad alignment: 1–3 bottom, 4–6 middle, 7–9 top (left/centre/right).
    var alignment = 2
    var marginL: Double = 20
    var marginR: Double = 20
    var marginV: Double = 20
}

/// The [Script Info] and [V4+ Styles] sections of an ASS/SSA header.
struct ASSScript: Sendable {
    var playResX: Double = 384
    var playResY: Double = 288
    var styles: [String: ASSStyle] = [:]

    func style(named name: String) -> ASSStyle {
        styles[name] ?? styles[name.trimmingCharacters(in: CharacterSet(charactersIn: "*"))] ?? styles["Default"] ?? ASSStyle()
    }

    static func parse(header: String) -> ASSScript {
        var script = ASSScript()
        var section = ""
        var formatFields: [String] = []
        var hasPlayResX = false, hasPlayResY = false
        for rawLine in header.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line.lowercased(); continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if section == "[script info]" {
                if key == "playresx", let v = Double(value) { script.playResX = v; hasPlayResX = true }
                if key == "playresy", let v = Double(value) { script.playResY = v; hasPlayResY = true }
            } else if section.contains("styles") {
                if key == "format" {
                    formatFields = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                } else if key == "style" {
                    let style = parseStyle(value, fields: formatFields)
                    script.styles[style.name] = style
                }
            }
        }
        // Per the ASS spec, a missing dimension is derived from the other.
        if hasPlayResY && !hasPlayResX { script.playResX = script.playResY * 4 / 3 }
        if hasPlayResX && !hasPlayResY { script.playResY = script.playResX * 3 / 4 }
        return script
    }

    private static func parseStyle(_ value: String, fields: [String]) -> ASSStyle {
        let fieldNames = fields.isEmpty
            ? ["name", "fontname", "fontsize", "primarycolour", "secondarycolour", "outlinecolour", "backcolour",
               "bold", "italic", "underline", "strikeout", "scalex", "scaley", "spacing", "angle", "borderstyle",
               "outline", "shadow", "alignment", "marginl", "marginr", "marginv", "encoding"]
            : fields
        let parts = value.split(separator: ",", maxSplits: fieldNames.count - 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var s = ASSStyle()
        for (i, name) in fieldNames.enumerated() where i < parts.count {
            let v = parts[i]
            switch name {
            case "name": s.name = v
            case "fontname": s.fontName = v
            case "fontsize": s.fontSize = Double(v) ?? s.fontSize
            case "primarycolour": s.primary = SubtitleColor(ass: v) ?? s.primary
            case "outlinecolour", "tertiarycolour": s.outlineColor = SubtitleColor(ass: v) ?? s.outlineColor
            case "backcolour": s.backColor = SubtitleColor(ass: v) ?? s.backColor
            case "bold": s.bold = (Int(v) ?? 0) != 0
            case "italic": s.italic = (Int(v) ?? 0) != 0
            case "underline": s.underline = (Int(v) ?? 0) != 0
            case "borderstyle": s.borderStyle = Int(v) ?? 1
            case "outline": s.outline = Double(v) ?? s.outline
            case "shadow": s.shadow = Double(v) ?? s.shadow
            case "alignment":
                // SSA (v4) uses 1–3 bottom, +4 top, +8 middle; ASS (v4+) uses numpad.
                let a = Int(v) ?? 2
                s.alignment = fields.contains("tertiarycolour") ? ssaToNumpad(a) : a
            case "marginl": s.marginL = Double(v) ?? s.marginL
            case "marginr": s.marginR = Double(v) ?? s.marginR
            case "marginv": s.marginV = Double(v) ?? s.marginV
            default: break
            }
        }
        return s
    }

    static func ssaToNumpad(_ a: Int) -> Int {
        let h = a & 3 == 0 ? 2 : a & 3
        if a & 4 != 0 { return h + 6 }       // top
        if a & 8 != 0 { return h + 3 }       // middle
        return h
    }
}

/// A run of text with uniform formatting.
struct ASSRun: Equatable, Sendable {
    var text: String
    var bold: Bool
    var italic: Bool
    var underline: Bool
    var fontName: String
    /// Script pixels (relative to PlayResY).
    var fontSize: Double
    var color: SubtitleColor
    var outlineColor: SubtitleColor
}

/// One dialogue event, ready to lay out.
struct ASSEvent: Equatable, Sendable {
    var layer = 0
    var styleName = "Default"
    var runs: [ASSRun] = []
    var alignment = 2
    /// \pos(x, y) in script coordinates, if given.
    var position: (x: Double, y: Double)?
    var marginL: Double = 0, marginR: Double = 0, marginV: Double = 0
    var outline: Double = 2
    var shadow: Double = 0
    var borderStyle = 1
    var backColor = SubtitleColor(red: 0, green: 0, blue: 0, alpha: 0.5)
    /// The script's coordinate space (PlayResX × PlayResY) that sizes and positions refer to.
    var playResX: Double = 384
    var playResY: Double = 288

    var plainText: String { runs.map(\.text).joined() }

    static func == (a: ASSEvent, b: ASSEvent) -> Bool {
        a.layer == b.layer && a.styleName == b.styleName && a.runs == b.runs && a.alignment == b.alignment
            && a.position?.x == b.position?.x && a.position?.y == b.position?.y
    }

    /// Parses an FFmpeg ASS event line:
    /// "ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text"
    /// (also accepts a full "Dialogue: Layer,Start,End,Style,…" line).
    static func parse(_ line: String, script: ASSScript) -> ASSEvent? {
        var body = line
        var fieldsBeforeText = 8      // ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect
        var layerIndex = 1, styleIndex = 2, marginIndex = 4
        if body.hasPrefix("Dialogue:") {
            body = String(body.dropFirst("Dialogue:".count)).trimmingCharacters(in: .whitespaces)
            fieldsBeforeText = 9      // Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect
            layerIndex = 0; styleIndex = 3; marginIndex = 5
        }
        let parts = body.split(separator: ",", maxSplits: fieldsBeforeText, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == fieldsBeforeText + 1 else { return nil }
        let style = script.style(named: parts[styleIndex].trimmingCharacters(in: .whitespaces))
        var event = ASSEvent()
        event.layer = Int(parts[layerIndex].trimmingCharacters(in: .whitespaces)) ?? 0
        event.styleName = style.name
        event.alignment = style.alignment
        func margin(_ i: Int, _ fallback: Double) -> Double {
            let v = Double(parts[marginIndex + i].trimmingCharacters(in: .whitespaces)) ?? 0
            return v > 0 ? v : fallback
        }
        event.marginL = margin(0, style.marginL)
        event.marginR = margin(1, style.marginR)
        event.marginV = margin(2, style.marginV)
        event.outline = style.outline
        event.shadow = style.shadow
        event.borderStyle = style.borderStyle
        event.backColor = style.backColor
        event.playResX = script.playResX
        event.playResY = script.playResY
        event.runs = parseText(parts[fieldsBeforeText], style: style, event: &event, script: script)
        return event.runs.isEmpty ? nil : event
    }

    /// Splits text into runs, applying override tags. Unsupported tags (animation, karaoke,
    /// clipping, drawing commands) are ignored; drawings are dropped.
    static func parseText(_ text: String, style: ASSStyle, event: inout ASSEvent, script: ASSScript) -> [ASSRun] {
        var runs: [ASSRun] = []
        var current = ASSRun(text: "", bold: style.bold, italic: style.italic, underline: style.underline,
                             fontName: style.fontName, fontSize: style.fontSize, color: style.primary,
                             outlineColor: style.outlineColor)
        var drawing = false
        func flush() {
            if !current.text.isEmpty {
                if let last = runs.last, last.bold == current.bold, last.italic == current.italic,
                   last.underline == current.underline, last.fontName == current.fontName,
                   last.fontSize == current.fontSize, last.color == current.color {
                    runs[runs.count - 1].text += current.text
                } else {
                    runs.append(current)
                }
            }
            current.text = ""
        }
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "{", let close = text[i...].firstIndex(of: "}") {
                flush()
                applyOverrides(String(text[text.index(after: i)..<close]), to: &current, style: style,
                               event: &event, drawing: &drawing)
                i = text.index(after: close)
                continue
            }
            if c == "\\", text.index(after: i) < text.endIndex {
                let n = text[text.index(after: i)]
                if n == "N" || n == "n" { if !drawing { current.text += "\n" }; i = text.index(i, offsetBy: 2); continue }
                if n == "h" { if !drawing { current.text += "\u{00A0}" }; i = text.index(i, offsetBy: 2); continue }
            }
            if !drawing { current.text.append(c) }
            i = text.index(after: i)
        }
        flush()
        // Trim trailing newlines that would add empty lines.
        while let last = runs.last, last.text.hasSuffix("\n") {
            runs[runs.count - 1].text.removeLast()
            if runs[runs.count - 1].text.isEmpty { runs.removeLast() }
        }
        return runs
    }

    private static func applyOverrides(_ block: String, to run: inout ASSRun, style: ASSStyle,
                                       event: inout ASSEvent, drawing: inout Bool) {
        // Tags are separated by backslashes: \i1\b0\pos(10,20)\c&H00FFFF&
        for raw in block.split(separator: "\\").map(String.init) where !raw.isEmpty {
            let tag = raw.trimmingCharacters(in: .whitespaces)
            func arg(_ prefix: String) -> String? { tag.hasPrefix(prefix) ? String(tag.dropFirst(prefix.count)) : nil }
            if let v = arg("pos(") {
                let nums = v.replacingOccurrences(of: ")", with: "").split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if nums.count >= 2 { event.position = (nums[0], nums[1]) }
            } else if let v = arg("an"), let a = Int(v), (1...9).contains(a) {
                event.alignment = a
            } else if tag.hasPrefix("a"), !tag.hasPrefix("alpha"), let a = Int(tag.dropFirst()), a > 0 {
                event.alignment = ASSScript.ssaToNumpad(a)
            } else if let v = arg("fn") {
                run.fontName = v.isEmpty ? style.fontName : v
            } else if let v = arg("fs"), let size = Double(v) {
                run.fontSize = size > 0 ? size : style.fontSize
            } else if tag == "fs" {
                run.fontSize = style.fontSize
            } else if let v = arg("1c") ?? arg("c"), !tag.hasPrefix("clip") {
                run.color = SubtitleColor(ass: v).map { var c = $0; c.alpha = run.color.alpha; return c } ?? style.primary
            } else if let v = arg("3c") {
                run.outlineColor = SubtitleColor(ass: v).map { var c = $0; c.alpha = run.outlineColor.alpha; return c } ?? style.outlineColor
            } else if let v = arg("1a") ?? arg("alpha"), let a = SubtitleColor(ass: v + "000000") {
                run.color.alpha = a.alpha
            } else if let v = arg("bord"), let b = Double(v) {
                event.outline = b
            } else if let v = arg("shad"), let s = Double(v) {
                event.shadow = s
            } else if let v = arg("p"), let p = Int(v) {
                drawing = p > 0
            } else if tag == "r" || tag.hasPrefix("r") && !tag.hasPrefix("rnd") {
                run.bold = style.bold; run.italic = style.italic; run.underline = style.underline
                run.fontName = style.fontName; run.fontSize = style.fontSize
                run.color = style.primary; run.outlineColor = style.outlineColor
            } else if let v = arg("i"), let n = Int(v) {
                run.italic = n != 0
            } else if tag.hasPrefix("b"), !tag.hasPrefix("bord"), !tag.hasPrefix("be"), !tag.hasPrefix("blur"),
                      let n = Int(tag.dropFirst()) {
                run.bold = n != 0
            } else if let v = arg("u"), let n = Int(v) {
                run.underline = n != 0
            }
            // \fad, \move, \t, \k, \clip, \org, \fr, \fsc, \blur … are ignored.
        }
    }
}
