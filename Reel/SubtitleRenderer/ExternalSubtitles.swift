import Foundation
import CFFmpeg

/// Finds and loads subtitle files that sit next to a video:
/// "Movie.srt", "Movie.en.srt", "Movie.eng.forced.ass", "Movie.English.sdh.srt" …
enum ExternalSubtitles {
    static let extensions: Set<String> = ["srt", "ass", "ssa", "vtt"]

    struct Candidate: Equatable {
        var url: URL
        var language: String?
        var forced: Bool
        var hearingImpaired: Bool
    }

    static func find(for video: URL) -> [Candidate] {
        let dir = video.deletingLastPathComponent()
        let base = video.deletingPathExtension().lastPathComponent.lowercased()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.sorted().compactMap { name -> Candidate? in
            let url = dir.appendingPathComponent(name)
            guard extensions.contains(url.pathExtension.lowercased()) else { return nil }
            let stem = url.deletingPathExtension().lastPathComponent
            guard stem.lowercased() == base || stem.lowercased().hasPrefix(base + ".") else { return nil }
            let tags = stem.dropFirst(base.count).split(separator: ".").map { $0.lowercased() }
            return Candidate(url: url, language: tags.compactMap(languageCode).first,
                             forced: tags.contains("forced"),
                             hearingImpaired: tags.contains("sdh") || tags.contains("hi") || tags.contains("cc"))
        }
    }

    /// "en", "eng", "english" → ISO 639-2 "eng"-style code (returned as given when it looks like one).
    static func languageCode(_ tag: String) -> String? {
        let names = ["english": "eng", "french": "fre", "german": "ger", "spanish": "spa", "italian": "ita",
                     "japanese": "jpn", "chinese": "chi", "korean": "kor", "dutch": "dut", "portuguese": "por",
                     "russian": "rus", "arabic": "ara", "hindi": "hin", "urdu": "urd", "turkish": "tur",
                     "swedish": "swe", "norwegian": "nor", "danish": "dan", "finnish": "fin", "polish": "pol"]
        if let code = names[tag] { return code }
        if ["forced", "sdh", "hi", "cc", "default"].contains(tag) { return nil }
        if tag.count == 2 || tag.count == 3, tag.allSatisfy({ $0.isLetter }) { return tag }
        return nil
    }

    /// Decodes a whole subtitle file. Text that isn't valid UTF-8 (or UTF-16 with a BOM) is
    /// treated as Windows-1252, the most common legacy encoding for .srt files.
    static func load(_ url: URL) throws -> (cues: [SubtitleCue], codecName: String) {
        let encoding = legacyEncoding(of: url)
        let file = try MediaFile(url: url, options: MediaProbe.Options(probeSize: 1_000_000, analyzeDuration: 0))
        guard let stream = (0..<Int(file.formatContext.pointee.nb_streams)).lazy
            .compactMap({ file.stream(at: $0) })
            .first(where: { $0.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE })
        else { throw FFmpegError(code: reel_averror_stream_not_found(), context: url.lastPathComponent) }

        let decoder = try SubtitleDecoder(stream: stream, startTime: 0, characterEncoding: encoding)
        var cues: [SubtitleCue] = []
        let raw = av_packet_alloc()
        var rawOpt = raw
        defer { av_packet_free(&rawOpt) }
        guard let raw else { return ([], decoder.codecName) }
        while av_read_frame(file.formatContext, raw) >= 0 {
            guard raw.pointee.stream_index == stream.pointee.index, let p = Packet(moving: raw, generation: 0) else {
                av_packet_unref(raw); continue
            }
            cues += decoder.decode(p)
        }
        return (cues.sorted { $0.start < $1.start }, decoder.codecName)
    }

    static func legacyEncoding(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) || data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return nil   // UTF-8 / UTF-16 with BOM: FFmpeg handles these itself
        }
        return String(data: data, encoding: .utf8) == nil ? "CP1252" : nil
    }
}
