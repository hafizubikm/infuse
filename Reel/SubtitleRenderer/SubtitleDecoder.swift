import Foundation
import CFFmpeg

/// Decodes one subtitle stream with FFmpeg into `SubtitleCue`s.
///
/// FFmpeg's text decoders (SubRip, mov_text, WebVTT, ASS …) all produce ASS events, so a single
/// ASS renderer handles every text format. Bitmap formats (PGS, VobSub, DVB) produce paletted
/// rectangles that are converted to RGBA here.
final class SubtitleDecoder {
    let codecName: String
    let isBitmap: Bool
    private(set) var script: ASSScript
    private var context: UnsafeMutablePointer<AVCodecContext>?
    private let timeBase: AVRational
    private let startSeconds: Double
    private let canvasWidth: Int
    private let canvasHeight: Int

    /// - Parameter characterEncoding: for external text files that aren't UTF-8 (e.g. "CP1252").
    init(stream: UnsafeMutablePointer<AVStream>, startTime: Int64, characterEncoding: String? = nil) throws {
        let par = stream.pointee.codecpar!
        codecName = ffString(avcodec_get_name(par.pointee.codec_id)) ?? "?"
        isBitmap = CodecNames.isBitmapSubtitle(codec: codecName)
        timeBase = stream.pointee.time_base
        startSeconds = Double(startTime) / Double(AV_TIME_BASE)
        guard let codec = avcodec_find_decoder(par.pointee.codec_id) else {
            throw AudioDecoder.DecoderError.noDecoder(codecName)
        }
        context = avcodec_alloc_context3(codec)
        guard let context else { throw FFmpegError(code: reel_averror(ENOMEM), context: "alloc") }
        try ffCheck(avcodec_parameters_to_context(context, par), "avcodec_parameters_to_context")
        context.pointee.pkt_timebase = stream.pointee.time_base
        var options: OpaquePointer?
        defer { av_dict_free(&options) }
        if let characterEncoding {
            av_dict_set(&options, "sub_charenc", characterEncoding, 0)
            av_dict_set(&options, "sub_charenc_mode", "pre_decoder", 0)
        }
        try ffCheck(avcodec_open2(context, codec, &options), "Opening \(codecName) subtitle decoder")

        // The ASS header (styles, PlayRes): from the decoder (converted formats) or the stream.
        if let header = context.pointee.subtitle_header, context.pointee.subtitle_header_size > 0 {
            script = ASSScript.parse(header: String(cString: header))
        } else if let extradata = par.pointee.extradata, par.pointee.extradata_size > 0 {
            script = ASSScript.parse(header: String(decoding: UnsafeBufferPointer(start: extradata, count: Int(par.pointee.extradata_size)), as: UTF8.self))
        } else {
            script = ASSScript()
        }
        canvasWidth = Int(context.pointee.width > 0 ? context.pointee.width : par.pointee.width)
        canvasHeight = Int(context.pointee.height > 0 ? context.pointee.height : par.pointee.height)
    }

    deinit { avcodec_free_context(&context) }

    func flush() {
        if let context { avcodec_flush_buffers(context) }
    }

    /// Decodes one packet into zero or more cues (times in media seconds).
    func decode(_ packet: Packet) -> [SubtitleCue] {
        guard let context, let pts = packet.bestTimestamp else { return [] }
        var sub = AVSubtitle()
        var got: Int32 = 0
        let ret = avcodec_decode_subtitle2(context, &sub, &got, packet.pointer)
        guard ret >= 0, got != 0 else { return [] }
        defer { avsubtitle_free(&sub) }

        let base = Double(pts) * timeBase.doubleValue - startSeconds
        let start = base + Double(sub.start_display_time) / 1000
        var end: Double?
        if sub.end_display_time > 0 && sub.end_display_time != UInt32.max {
            end = base + Double(sub.end_display_time) / 1000
        } else if packet.duration > 0 {
            end = base + Double(packet.duration) * timeBase.doubleValue
        }

        var events: [ASSEvent] = []
        var bitmaps: [SubtitleBitmap] = []
        for i in 0..<Int(sub.num_rects) {
            guard let rect = sub.rects[i]?.pointee else { continue }
            switch rect.type {
            case SUBTITLE_ASS:
                if let ass = rect.ass, let event = ASSEvent.parse(String(cString: ass), script: script) {
                    events.append(event)
                }
            case SUBTITLE_TEXT:
                if let text = rect.text {
                    let line = "0,0,Default,,0,0,0,," + String(cString: text).replacingOccurrences(of: "\n", with: "\\N")
                    if let event = ASSEvent.parse(line, script: script) { events.append(event) }
                }
            case SUBTITLE_BITMAP:
                if let bitmap = convert(rect) { bitmaps.append(bitmap) }
            default:
                break
            }
        }

        if isBitmap {
            // Bitmap display sets replace what is on screen; an empty one just clears.
            if bitmaps.isEmpty && end == nil && sub.num_rects == 0 {
                return [SubtitleCue(start: start, end: start, content: .bitmaps([], canvasWidth: canvasWidth, canvasHeight: canvasHeight))]
            }
            guard !bitmaps.isEmpty else { return [] }
            return [SubtitleCue(start: start, end: end,
                                content: .bitmaps(bitmaps, canvasWidth: canvasWidth, canvasHeight: canvasHeight))]
        }
        guard !events.isEmpty else { return [] }
        return [SubtitleCue(start: start, end: end ?? start + 5, content: .text(events))]
    }

    /// PAL8 → RGBA. FFmpeg palettes are native-endian 0xAARRGGBB words.
    private func convert(_ rect: AVSubtitleRect) -> SubtitleBitmap? {
        let w = Int(rect.w), h = Int(rect.h)
        guard w > 0, h > 0, let indices = rect.data.0, let paletteBytes = rect.data.1 else { return nil }
        let stride = Int(rect.linesize.0)
        let palette = UnsafeRawPointer(paletteBytes).assumingMemoryBound(to: UInt32.self)
        let colors = max(1, Int(rect.nb_colors))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBufferPointer { out in
            for y in 0..<h {
                for x in 0..<w {
                    let index = Int(indices[y * stride + x])
                    let argb = index < colors ? palette[index] : 0
                    let o = (y * w + x) * 4
                    out[o] = UInt8((argb >> 16) & 0xFF)
                    out[o + 1] = UInt8((argb >> 8) & 0xFF)
                    out[o + 2] = UInt8(argb & 0xFF)
                    out[o + 3] = UInt8(argb >> 24)
                }
            }
        }
        return SubtitleBitmap(x: Int(rect.x), y: Int(rect.y), width: w, height: h, rgba: rgba,
                              forced: rect.flags & AV_SUBTITLE_FLAG_FORCED != 0)
    }
}
