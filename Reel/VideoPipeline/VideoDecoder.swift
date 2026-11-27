import Foundation
import CoreVideo
import CFFmpeg

/// FFmpeg video decoder for codecs the compressed path can't hand to AVSampleBufferDisplayLayer
/// (MPEG-2, VC-1, VP9, VP8, MPEG-4 ASP, H.264 Hi10P …). Uses FFmpeg's VideoToolbox hwaccel
/// when the codec supports it (frames then arrive as CVPixelBuffers), software otherwise.
final class VideoDecoder {
    let codecName: String
    private var context: UnsafeMutablePointer<AVCodecContext>?
    private var frame: UnsafeMutablePointer<AVFrame>?
    private var hwDevice: UnsafeMutablePointer<AVBufferRef>?
    /// Known after the first decoded frame.
    private(set) var usesHardware: Bool?

    init(stream: UnsafeMutablePointer<AVStream>, allowHardware: Bool = true) throws {
        let par = stream.pointee.codecpar!
        codecName = ffString(avcodec_get_name(par.pointee.codec_id)) ?? "?"
        guard let codec = avcodec_find_decoder(par.pointee.codec_id) else {
            throw AudioDecoder.DecoderError.noDecoder(codecName)
        }
        context = avcodec_alloc_context3(codec)
        frame = av_frame_alloc()
        guard let context, frame != nil else { throw FFmpegError(code: reel_averror(ENOMEM), context: "alloc") }
        try ffCheck(avcodec_parameters_to_context(context, par), "avcodec_parameters_to_context")
        context.pointee.pkt_timebase = stream.pointee.time_base
        context.pointee.thread_count = 0   // automatic (frame + slice threads for software decoding)

        if allowHardware, av_hwdevice_ctx_create(&hwDevice, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0 {
            context.pointee.hw_device_ctx = av_buffer_ref(hwDevice)
            context.pointee.get_format = reelPreferVideoToolbox
        }
        try ffCheck(avcodec_open2(context, codec, nil), "Opening \(codecName) decoder")
    }

    deinit {
        avcodec_free_context(&context)
        av_frame_free(&frame)
        av_buffer_unref(&hwDevice)
    }

    func flush() {
        if let context { avcodec_flush_buffers(context) }
    }

    /// Decodes one packet (nil = drain) and calls `handler` for every frame, in display order.
    /// The frame is only valid during the call.
    func decode(_ packet: Packet?, handler: (UnsafeMutablePointer<AVFrame>) -> Void) {
        guard let context, let frame else { return }
        let sent = avcodec_send_packet(context, packet?.pointer)
        if sent < 0 && sent != reel_averror_eagain() && sent != reel_averror_eof() {
            Log.video.error("\(self.codecName, privacy: .public) decode error: \(FFmpegError.message(for: sent), privacy: .public)")
        }
        while avcodec_receive_frame(context, frame) >= 0 {
            if usesHardware == nil {
                usesHardware = frame.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue
                Log.video.notice("\(self.codecName, privacy: .public): \(self.usesHardware! ? "VideoToolbox" : "software", privacy: .public) decoding")
            }
            handler(frame)
            av_frame_unref(frame)
        }
    }
}

/// get_format callback: pick VideoToolbox frames when FFmpeg offers them, else the default.
/// (If the hwaccel then fails to initialise, FFmpeg asks again without VideoToolbox.)
private func reelPreferVideoToolbox(_ ctx: UnsafeMutablePointer<AVCodecContext>?,
                                    _ formats: UnsafePointer<AVPixelFormat>?) -> AVPixelFormat {
    guard var p = formats else { return AV_PIX_FMT_NONE }
    while p.pointee != AV_PIX_FMT_NONE {
        if p.pointee == AV_PIX_FMT_VIDEOTOOLBOX { return AV_PIX_FMT_VIDEOTOOLBOX }
        p += 1
    }
    return avcodec_default_get_format(ctx, formats)
}
