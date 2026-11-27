// FFmpegShim.h — FFmpeg headers + helpers for things Swift cannot import directly
// (function-like macros, compound-literal constants, variadic logging).
#ifndef REEL_FFMPEG_SHIM_H
#define REEL_FFMPEG_SHIM_H

#include <stdint.h>
#include <stddef.h>
#include <errno.h>

#include <libavformat/avformat.h>
#include <libavformat/avio.h>
#include <libavcodec/avcodec.h>
#include <libavcodec/bsf.h>
#include <libavcodec/defs.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dict.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/error.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

#ifdef __APPLE__
#include <libavutil/hwcontext_videotoolbox.h>
#endif

// MARK: - Error codes (AVERROR / FFERRTAG are macros)

static inline int reel_averror(int posix_errno) { return AVERROR(posix_errno); }
static inline int reel_averror_eof(void) { return AVERROR_EOF; }
static inline int reel_averror_eagain(void) { return AVERROR(EAGAIN); }
static inline int reel_averror_exit(void) { return AVERROR_EXIT; }
static inline int reel_averror_invaliddata(void) { return AVERROR_INVALIDDATA; }
static inline int reel_averror_decoder_not_found(void) { return AVERROR_DECODER_NOT_FOUND; }
static inline int reel_averror_stream_not_found(void) { return AVERROR_STREAM_NOT_FOUND; }
static inline int reel_averror_eio(void) { return AVERROR(EIO); }

/// Writes a human readable description of an FFmpeg error code into `buf`.
static inline void reel_err2str(int errnum, char *_Nonnull buf, size_t size) {
    if (av_strerror(errnum, buf, size) < 0) {
        snprintf(buf, size, "FFmpeg error %d", errnum);
    }
}

// MARK: - Constants defined as non-trivial macros

static inline int64_t reel_nopts_value(void) { return AV_NOPTS_VALUE; }
static inline AVRational reel_time_base_q(void) { return AV_TIME_BASE_Q; }
static inline int reel_avseek_size(void) { return AVSEEK_SIZE; }
static inline int reel_avseek_force(void) { return AVSEEK_FORCE; }

// MARK: - Logging

/// Receives one fully formatted FFmpeg log line (without trailing newline).
typedef void (*ReelLogHandler)(int level, const char *_Nonnull line);

/// Routes av_log output to `handler` for messages at or below `max_level`
/// (e.g. AV_LOG_WARNING). Pass NULL to restore FFmpeg's default stderr logger.
void reel_set_log_handler(ReelLogHandler _Nullable handler, int max_level);

#endif /* REEL_FFMPEG_SHIM_H */
