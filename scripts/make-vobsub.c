// Writes a tiny Matroska file with a VobSub (DVD bitmap) subtitle track for Reel's tests.
// Dev tool only, used by scripts/make-fixtures.sh:
//   cc -o make-vobsub scripts/make-vobsub.c $(pkg-config --cflags --libs libavformat libavcodec libavutil)
//   ./make-vobsub TestMedia/vobsub.mkv
//
// Cue 1 (0.5–1.5 s): a 200×40 white box with a black border at (260, 400) on a 720×480 canvas.
// Cue 2 (2.0–2.5 s): a 100×20 yellow box at (310, 40), flagged as forced.
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <string.h>

static int write_cue(AVFormatContext *oc, AVStream *st, AVCodecContext *enc, int64_t start_ms, int duration_ms,
                     int x, int y, int w, int h, uint32_t fill, int forced) {
    AVSubtitle sub = {0};
    AVSubtitleRect rect = {0};
    AVSubtitleRect *rects[1] = {&rect};
    uint32_t palette[4] = {0x00000000, fill, 0xFF000000, 0xFF808080};
    uint8_t *indices = av_mallocz(w * h);
    for (int j = 0; j < h; j++)
        for (int i = 0; i < w; i++)
            indices[j * w + i] = (i < 2 || j < 2 || i >= w - 2 || j >= h - 2) ? 2 : 1;
    rect.type = SUBTITLE_BITMAP;
    rect.x = x; rect.y = y; rect.w = w; rect.h = h;
    rect.nb_colors = 4;
    rect.data[0] = indices; rect.linesize[0] = w;
    rect.data[1] = (uint8_t *)palette; rect.linesize[1] = 4 * 4;
    rect.flags = forced ? AV_SUBTITLE_FLAG_FORCED : 0;
    sub.num_rects = 1;
    sub.rects = rects;
    sub.start_display_time = 0;
    sub.end_display_time = duration_ms;
    sub.pts = av_rescale_q(start_ms, (AVRational){1, 1000}, AV_TIME_BASE_Q);

    uint8_t buf[1 << 16];
    int size = avcodec_encode_subtitle(enc, buf, sizeof(buf), &sub);
    av_free(indices);
    if (size < 0) return size;
    AVPacket *pkt = av_packet_alloc();
    av_new_packet(pkt, size);
    memcpy(pkt->data, buf, size);
    pkt->stream_index = st->index;
    pkt->pts = pkt->dts = av_rescale_q(start_ms, (AVRational){1, 1000}, st->time_base);
    pkt->duration = av_rescale_q(duration_ms, (AVRational){1, 1000}, st->time_base);
    pkt->flags |= AV_PKT_FLAG_KEY;
    int ret = av_interleaved_write_frame(oc, pkt);
    av_packet_free(&pkt);
    return ret;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s out.mkv\n", argv[0]); return 1; }
    AVFormatContext *oc = NULL;
    if (avformat_alloc_output_context2(&oc, NULL, "matroska", argv[1]) < 0) return 1;
    const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_DVD_SUBTITLE);
    AVCodecContext *enc = avcodec_alloc_context3(codec);
    enc->width = 720; enc->height = 480;
    enc->time_base = (AVRational){1, 1000};
    if (avcodec_open2(enc, codec, NULL) < 0) { fprintf(stderr, "cannot open dvdsub encoder\n"); return 1; }
    AVStream *st = avformat_new_stream(oc, NULL);
    avcodec_parameters_from_context(st->codecpar, enc);
    st->time_base = (AVRational){1, 1000};
    av_dict_set(&st->metadata, "language", "eng", 0);
    if (avio_open(&oc->pb, argv[1], AVIO_FLAG_WRITE) < 0) return 1;
    if (avformat_write_header(oc, NULL) < 0) return 1;
    if (write_cue(oc, st, enc, 500, 1000, 260, 400, 200, 40, 0xFFFFFFFF, 0) < 0) return 1;
    if (write_cue(oc, st, enc, 2000, 500, 310, 40, 100, 20, 0xFFFFFF00, 1) < 0) return 1;
    av_write_trailer(oc);
    avio_closep(&oc->pb);
    avformat_free_context(oc);
    avcodec_free_context(&enc);
    return 0;
}
