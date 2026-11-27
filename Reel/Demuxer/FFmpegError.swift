import Foundation
import CFFmpeg

/// An FFmpeg return code (< 0) with context about which call failed.
struct FFmpegError: Error, CustomStringConvertible, Equatable {
    let code: Int32
    let context: String

    var description: String { "\(context): \(Self.message(for: code)) (\(code))" }

    var isEOF: Bool { code == reel_averror_eof() }
    var isAgain: Bool { code == reel_averror_eagain() }
    var isIOError: Bool { code == reel_averror_eio() || code == reel_averror(ENXIO) || code == reel_averror(ENODEV) }

    static func message(for code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        reel_err2str(code, &buffer, buffer.count)
        return String(cString: buffer)
    }
}

/// Throws `FFmpegError` when `ret` is negative, otherwise returns it.
@discardableResult
func ffCheck(_ ret: Int32, _ context: @autoclosure () -> String) throws -> Int32 {
    if ret < 0 { throw FFmpegError(code: ret, context: context()) }
    return ret
}

extension AVRational {
    var doubleValue: Double { den == 0 ? 0 : Double(num) / Double(den) }
    var isValid: Bool { num != 0 && den != 0 }
}

/// FFmpeg's AV_NOPTS_VALUE, which Swift cannot import as a constant.
let ffNoPTS: Int64 = reel_nopts_value()

func ffString(_ cString: UnsafePointer<CChar>?) -> String? {
    guard let cString else { return nil }
    let s = String(cString: cString)
    return s.isEmpty ? nil : s
}
