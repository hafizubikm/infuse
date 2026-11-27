import Foundation
#if canImport(os)
import os
#endif
import CFFmpeg

/// Unified-logging categories. View with: log stream --predicate 'subsystem == "app.reel.player"'
enum Log {
    static let subsystem = "app.reel.player"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let ffmpeg = Logger(subsystem: subsystem, category: "ffmpeg")
    static let demux = Logger(subsystem: subsystem, category: "demux")
    static let video = Logger(subsystem: subsystem, category: "video")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let subtitles = Logger(subsystem: subsystem, category: "subtitles")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let library = Logger(subsystem: subsystem, category: "library")
}

enum FFmpegLogging {
    /// Routes FFmpeg's own log output (warnings and errors) into unified logging.
    static func install() {
        reel_set_log_handler({ level, line in
            let text = String(cString: line)
            if level <= AV_LOG_ERROR {
                Log.ffmpeg.error("\(text, privacy: .public)")
            } else {
                Log.ffmpeg.notice("\(text, privacy: .public)")
            }
        }, AV_LOG_WARNING)
    }
}
