import Foundation
import CFFmpeg

/// Owns an opened `AVFormatContext` for one media file.
///
/// Not thread-safe: use one instance per thread (the demuxer thread owns its own).
final class MediaFile {
    let url: URL
    let formatContext: UnsafeMutablePointer<AVFormatContext>
    /// Custom I/O used for playback (nil when FFmpeg's own file protocol is used, e.g. probing).
    let io: FileIO?
    private(set) lazy var info: MediaInfo = MediaProbe.describe(formatContext, url: url)

    /// Start time of the container in AV_TIME_BASE units (non-zero for most transport streams).
    var startTime: Int64 {
        let st = formatContext.pointee.start_time
        return st == ffNoPTS ? 0 : st
    }

    /// - Parameter useCustomIO: read through `FileIO` (buffered pread, unplug-aware, abortable).
    init(url: URL, options: MediaProbe.Options = .default, useCustomIO: Bool = false) throws {
        self.url = url
        let io = useCustomIO ? try FileIO(url: url) : nil
        self.io = io

        var ctx = avformat_alloc_context()
        guard let allocated = ctx else {
            throw FFmpegError(code: reel_averror(ENOMEM), context: "avformat_alloc_context")
        }
        allocated.pointee.probesize = options.probeSize
        allocated.pointee.max_analyze_duration = options.analyzeDuration
        if let io {
            allocated.pointee.pb = io.context
            allocated.pointee.flags |= AVFMT_FLAG_CUSTOM_IO
            allocated.pointee.interrupt_callback = AVIOInterruptCB(
                callback: fileIOInterrupt, opaque: Unmanaged.passUnretained(io).toOpaque())
        }

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
        // `io` (and its AVIOContext) is released after the format context is closed.
    }

    /// Decodes the first frame of E-AC-3 / TrueHD / DTS tracks to find Atmos and DTS:X (see
    /// AudioFeatureDetector), updates `info`, and rewinds the file to the start.
    func detectAudioFeatures() {
        let features = AudioFeatureDetector.detect(in: self)
        guard !features.isEmpty else { return }
        var updated = info
        for i in updated.streams.indices {
            guard let f = features[updated.streams[i].index], var audio = updated.streams[i].audio else { continue }
            audio.isAtmos = audio.isAtmos || f.isAtmos
            audio.isDTSX = audio.isDTSX || f.isDTSX
            updated.streams[i].audio = audio
        }
        info = updated
    }

    func stream(at index: Int) -> UnsafeMutablePointer<AVStream>? {
        guard index >= 0, index < Int(formatContext.pointee.nb_streams) else { return nil }
        return formatContext.pointee.streams[index]
    }

    /// Makes pending and future reads fail fast so the demux thread can exit.
    func abort() { io?.abort() }
}
