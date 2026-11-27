import Foundation
import CFFmpeg

/// Finds Dolby Atmos (E-AC-3 JOC, TrueHD) and DTS:X tracks.
///
/// FFmpeg only reports these as codec *profiles* after decoding a frame, and
/// avformat_find_stream_info usually doesn't decode audio whose parameters are already
/// known from the container. So this decodes the first frame(s) of each candidate track.
enum AudioFeatureDetector {
    struct Features: Equatable {
        var isAtmos = false
        var isDTSX = false
    }

    static func isCandidate(_ codecID: AVCodecID) -> Bool {
        codecID == AV_CODEC_ID_EAC3 || codecID == AV_CODEC_ID_TRUEHD || codecID == AV_CODEC_ID_DTS
    }

    /// Reads up to `maxPackets` packets from the current position, then rewinds to the start.
    static func detect(in file: MediaFile, maxPackets: Int = 600) -> [Int: Features] {
        let ctx = file.formatContext
        final class Probe {
            let codecID: AVCodecID
            var context: UnsafeMutablePointer<AVCodecContext>?
            var attempts = 0
            var done = false
            var features = Features()
            init(codecID: AVCodecID) { self.codecID = codecID }
            deinit { avcodec_free_context(&context) }
        }

        var probes: [Int: Probe] = [:]
        for i in 0..<Int(ctx.pointee.nb_streams) {
            guard let st = ctx.pointee.streams[i], st.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO,
                  isCandidate(st.pointee.codecpar.pointee.codec_id),
                  let codec = avcodec_find_decoder(st.pointee.codecpar.pointee.codec_id),
                  let dec = avcodec_alloc_context3(codec)
            else { continue }
            let probe = Probe(codecID: st.pointee.codecpar.pointee.codec_id)
            probe.context = dec
            guard avcodec_parameters_to_context(dec, st.pointee.codecpar) >= 0,
                  avcodec_open2(dec, codec, nil) >= 0 else { continue }
            probes[i] = probe
        }
        guard !probes.isEmpty else { return [:] }

        guard let packet = av_packet_alloc(), let frame = av_frame_alloc() else { return [:] }
        var pkt: UnsafeMutablePointer<AVPacket>? = packet
        var frm: UnsafeMutablePointer<AVFrame>? = frame
        defer { av_packet_free(&pkt); av_frame_free(&frm) }

        var read = 0
        while read < maxPackets, probes.values.contains(where: { !$0.done }) {
            guard av_read_frame(ctx, packet) >= 0 else { break }
            read += 1
            defer { av_packet_unref(packet) }
            guard let probe = probes[Int(packet.pointee.stream_index)], !probe.done, let dec = probe.context else { continue }
            probe.attempts += 1
            if avcodec_send_packet(dec, packet) >= 0 {
                while avcodec_receive_frame(dec, frame) >= 0 {
                    av_frame_unref(frame)
                    probe.done = true
                }
            }
            if probe.done || probe.attempts >= 40 {
                probe.done = true
                switch probe.codecID {
                case AV_CODEC_ID_EAC3: probe.features.isAtmos = dec.pointee.profile == AV_PROFILE_EAC3_DDP_ATMOS
                case AV_CODEC_ID_TRUEHD: probe.features.isAtmos = dec.pointee.profile == AV_PROFILE_TRUEHD_ATMOS
                case AV_CODEC_ID_DTS:
                    probe.features.isDTSX = dec.pointee.profile == AV_PROFILE_DTS_HD_MA_X
                        || dec.pointee.profile == AV_PROFILE_DTS_HD_MA_X_IMAX
                default: break
                }
            }
        }

        // Back to the beginning for whoever reads the file next.
        let start = file.startTime
        if avformat_seek_file(ctx, -1, Int64.min, start, start, 0) < 0 {
            _ = av_seek_frame(ctx, -1, start, AVSEEK_FLAG_BACKWARD)
        }
        return probes.mapValues(\.features)
    }
}
