import Foundation
import CFFmpeg

/// Decodes one audio stream with FFmpeg to interleaved Float32 PCM in the stream's own
/// channel order (no downmix), for codecs macOS can't decode itself (TrueHD, DTS, FLAC, Opus …).
final class AudioDecoder {
    struct Output {
        /// Presentation time of the first sample, in the stream's time base (nil if unknown).
        var pts: Int64?
        var sampleRate: Int
        var speakers: [Speaker]
        /// Interleaved Float32 samples: frameCount × speakers.count values.
        var samples: [Float]
        var frameCount: Int { speakers.isEmpty ? 0 : samples.count / speakers.count }
    }

    enum DecoderError: Error, CustomStringConvertible {
        case noDecoder(String)
        case ffmpeg(FFmpegError)
        var description: String {
            switch self {
            case .noDecoder(let c): return "No FFmpeg decoder for \(c)"
            case .ffmpeg(let e): return e.description
            }
        }
    }

    let codecName: String
    private var context: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var swr: OpaquePointer?
    private var swrInputFormat: Int32 = -1
    private var swrInputRate: Int32 = 0
    private var swrInputLayout = AVChannelLayout()
    private var outputLayout = AVChannelLayout()
    private var speakers: [Speaker] = []

    init(stream: UnsafeMutablePointer<AVStream>) throws {
        let par = stream.pointee.codecpar!
        codecName = ffString(avcodec_get_name(par.pointee.codec_id)) ?? "?"
        guard let codec = avcodec_find_decoder(par.pointee.codec_id) else { throw DecoderError.noDecoder(codecName) }
        context = avcodec_alloc_context3(codec)
        frame = av_frame_alloc()
        guard let context, frame != nil else { throw DecoderError.ffmpeg(FFmpegError(code: reel_averror(ENOMEM), context: "alloc")) }
        do {
            try ffCheck(avcodec_parameters_to_context(context, par), "avcodec_parameters_to_context")
            context.pointee.pkt_timebase = stream.pointee.time_base
            // TrueHD/DTS-HD can be decoded on several threads; harmless elsewhere.
            context.pointee.thread_count = 0
            try ffCheck(avcodec_open2(context, codec, nil), "Opening \(codecName) decoder")
        } catch let e as FFmpegError {
            throw DecoderError.ffmpeg(e)
        }
    }

    deinit {
        avcodec_free_context(&context)
        av_frame_free(&frame)
        swr_free(&swr)
        av_channel_layout_uninit(&swrInputLayout)
        av_channel_layout_uninit(&outputLayout)
    }

    /// Drops decoder state (after a seek).
    func flush() {
        if let context { avcodec_flush_buffers(context) }
    }

    /// Decodes one packet (nil = drain at end of stream) and returns the frames it produced.
    func decode(_ packet: Packet?) -> [Output] {
        guard let context, let frame else { return [] }
        let sent = avcodec_send_packet(context, packet?.pointer)
        if sent < 0 && sent != reel_averror_eagain() && sent != reel_averror_eof() {
            Log.audio.error("\(self.codecName, privacy: .public) decode error: \(FFmpegError.message(for: sent), privacy: .public)")
        }
        var outputs: [Output] = []
        while avcodec_receive_frame(context, frame) >= 0 {
            defer { av_frame_unref(frame) }
            if let out = convert(frame) { outputs.append(out) }
        }
        return outputs
    }

    private func convert(_ frame: UnsafeMutablePointer<AVFrame>) -> Output? {
        let f = frame.pointee
        let nb = Int(f.nb_samples)
        guard nb > 0, f.ch_layout.nb_channels > 0 else { return nil }
        guard prepareResampler(for: frame) else { return nil }

        let channels = Int(outputLayout.nb_channels)
        var samples = [Float](repeating: 0, count: nb * channels)
        let converted: Int32 = samples.withUnsafeMutableBytes { buf in
            var out: UnsafeMutablePointer<UInt8>? = buf.baseAddress?.assumingMemoryBound(to: UInt8.self)
            let input = UnsafeRawPointer(frame.pointee.extended_data).assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
            return swr_convert(swr, &out, Int32(nb), input, Int32(nb))
        }
        guard converted > 0 else { return nil }
        if Int(converted) < nb { samples.removeLast((nb - Int(converted)) * channels) }
        let ts = f.best_effort_timestamp != ffNoPTS ? f.best_effort_timestamp : (f.pts != ffNoPTS ? f.pts : nil)
        return Output(pts: ts, sampleRate: Int(f.sample_rate), speakers: speakers, samples: samples)
    }

    /// (Re)creates the resampler when the frame's format, rate or layout changes.
    private func prepareResampler(for frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        var inLayout = frame.pointee.ch_layout
        if inLayout.order == AV_CHANNEL_ORDER_UNSPEC {
            var d = AVChannelLayout()
            av_channel_layout_default(&d, inLayout.nb_channels)
            inLayout = d
        }
        if swr != nil, swrInputFormat == frame.pointee.format, swrInputRate == frame.pointee.sample_rate,
           av_channel_layout_compare(&swrInputLayout, &inLayout) == 0 {
            return true
        }
        swr_free(&swr)
        av_channel_layout_uninit(&swrInputLayout)
        av_channel_layout_uninit(&outputLayout)
        guard av_channel_layout_copy(&swrInputLayout, &inLayout) >= 0,
              av_channel_layout_copy(&outputLayout, &inLayout) >= 0 else { return false }
        let fmt = AVSampleFormat(rawValue: frame.pointee.format)
        let rate = frame.pointee.sample_rate
        guard swr_alloc_set_opts2(&swr, &outputLayout, AV_SAMPLE_FMT_FLT, rate,
                                  &swrInputLayout, fmt, rate, 0, nil) >= 0,
              swr_init(swr) >= 0 else {
            Log.audio.error("Could not set up the audio resampler")
            swr_free(&swr)
            return false
        }
        swrInputFormat = frame.pointee.format
        swrInputRate = rate
        speakers = SpeakerLayout.speakers(for: outputLayout)
        var name = [CChar](repeating: 0, count: 64)
        av_channel_layout_describe(&outputLayout, &name, name.count)
        Log.audio.notice("Decoding \(self.codecName, privacy: .public) → Float32 \(rate) Hz \(String(cString: name), privacy: .public)")
        return true
    }
}
