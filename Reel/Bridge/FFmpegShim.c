// FFmpegShim.c — the non-inline parts of the CFFmpeg shim module.
#include "FFmpegShim.h"

#include <stdatomic.h>
#include <string.h>

static _Atomic(ReelLogHandler) g_handler = NULL;
static atomic_int g_max_level = AV_LOG_WARNING;

static void reel_log_callback(void *avcl, int level, const char *fmt, va_list vl) {
    ReelLogHandler handler = atomic_load(&g_handler);
    if (handler == NULL || level > atomic_load(&g_max_level)) {
        return;
    }
    char line[1024];
    int print_prefix = 1;
    av_log_format_line2(avcl, level, fmt, vl, line, (int)sizeof(line), &print_prefix);
    size_t len = strlen(line);
    while (len > 0 && (line[len - 1] == '\n' || line[len - 1] == '\r')) {
        line[--len] = '\0';
    }
    if (len > 0) {
        handler(level, line);
    }
}

void reel_set_log_handler(ReelLogHandler handler, int max_level) {
    atomic_store(&g_max_level, max_level);
    atomic_store(&g_handler, handler);
    if (handler != NULL) {
        av_log_set_level(max_level);
        av_log_set_callback(reel_log_callback);
    } else {
        av_log_set_callback(av_log_default_callback);
    }
}
