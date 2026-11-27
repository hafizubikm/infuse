import Foundation
import CFFmpeg

/// Owns an opened `AVFormatContext` for one media file.
///
/// Not thread-safe: use one instance per thread (the demuxer thread owns its own).
final class MediaFile {
    let url: URL
    let formatContext: UnsafeMutablePointer<AVFormatContext>
    private(set) lazy var info: MediaInfo = MediaProbe.describe(formatContext, url: url)

    init(url: URL, options: MediaProbe.Options = .default) throws {
        self.url = url
        var ctx = avformat_alloc_context()
        guard let allocated = ctx else {
            throw FFmpegError(code: reel_averror(ENOMEM), context: "avformat_alloc_context")
        }
        allocated.pointee.probesize = options.probeSize
        allocated.pointee.max_analyze_duration = options.analyzeDuration

        var dict: OpaquePointer?
        defer { av_dict_free(&dict) }
        // MPEG-TS: look at every program map table so no stream is missed in broadcast captures.
        av_dict_set(&dict, "scan_all_pmts", "1", 0)

        // avformat_open_input frees `ctx` on failure.
        try ffCheck(avformat_open_input(&ctx, url.path, nil, &dict), "Opening \(url.lastPathComponent)")
        guard let opened = ctx else {
            throw FFmpegError(code: reel_averror_invaliddata(), context: "avformat_open_input")
        }
        formatContext = opened

        let ret = avformat_find_stream_info(opened, nil)
        if ret < 0 {
            var c: UnsafeMutablePointer<AVFormatContext>? = opened
            avformat_close_input(&c)
            throw FFmpegError(code: ret, context: "Reading stream info of \(url.lastPathComponent)")
        }
    }

    deinit {
        var c: UnsafeMutablePointer<AVFormatContext>? = formatContext
        avformat_close_input(&c)
    }

    func stream(at index: Int) -> UnsafeMutablePointer<AVStream>? {
        guard index >= 0, index < Int(formatContext.pointee.nb_streams) else { return nil }
        return formatContext.pointee.streams[index]
    }
}
