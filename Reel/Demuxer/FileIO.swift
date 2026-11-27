import Foundation
import CFFmpeg
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A thread-safe boolean (no Synchronization module on macOS 14).
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    init(_ value: Bool = false) { self.value = value }

    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
}

/// Feeds FFmpeg from a file through a custom AVIOContext.
///
/// - Positional reads (`pread`) with kernel read-ahead, called only from the demux thread.
/// - When an external drive disappears, reads fail with EIO/ENXIO/ENODEV; that errno is kept
///   in `lastErrno` so the player can say "drive disconnected" instead of "corrupt file".
/// - `abort()` makes any blocked or future read return AVERROR_EXIT (used when closing).
final class FileIO {
    enum OpenError: Error, CustomStringConvertible {
        case cannotOpen(path: String, errno: Int32)
        case outOfMemory

        var description: String {
            switch self {
            case .cannotOpen(let path, let code):
                return "Can't open \((path as NSString).lastPathComponent): \(String(cString: strerror(code)))"
            case .outOfMemory:
                return "Out of memory"
            }
        }
    }

    static let bufferSize = 1 << 20

    let url: URL
    let size: Int64
    private let fd: Int32
    private var position: Int64 = 0
    private let aborted = AtomicFlag()
    private let errnoLock = NSLock()
    private var _lastErrno: Int32 = 0
    private(set) var context: UnsafeMutablePointer<AVIOContext>!

    /// errno of the most recent failed read, 0 if none.
    var lastErrno: Int32 {
        errnoLock.lock(); defer { errnoLock.unlock() }
        return _lastErrno
    }

    /// True when the last failure looks like the device went away (unplugged / ejected).
    var deviceDisappeared: Bool {
        [EIO, ENXIO, ENODEV, ENOENT, EBADF].contains(lastErrno)
    }

    init(url: URL) throws {
        self.url = url
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw OpenError.cannotOpen(path: url.path, errno: errno) }
        self.fd = fd

        var st = stat()
        size = fstat(fd, &st) == 0 ? Int64(st.st_size) : -1
        #if canImport(Darwin)
        _ = fcntl(fd, F_RDAHEAD, 1)
        #endif

        guard let buffer = av_malloc(Self.bufferSize) else {
            close(fd)
            throw OpenError.outOfMemory
        }
        let opaque = Unmanaged.passUnretained(self).toOpaque()
        context = avio_alloc_context(
            buffer.assumingMemoryBound(to: UInt8.self), Int32(Self.bufferSize),
            0, opaque, fileIORead, nil, fileIOSeek)
        if context == nil {
            av_free(buffer)
            close(fd)
            throw OpenError.outOfMemory
        }
    }

    deinit {
        if context != nil {
            av_freep(&context.pointee.buffer)
            avio_context_free(&context)
        }
        close(fd)
    }

    func abort() { aborted.set(true) }
    var isAborted: Bool { aborted.get() }

    fileprivate func read(_ buf: UnsafeMutablePointer<UInt8>, _ count: Int) -> Int32 {
        if aborted.get() { return reel_averror_exit() }
        var n: Int
        repeat {
            n = pread(fd, buf, count, off_t(position))
        } while n < 0 && errno == EINTR
        if n < 0 {
            let code = errno
            errnoLock.lock(); _lastErrno = code; errnoLock.unlock()
            return reel_averror(code)
        }
        if n == 0 { return reel_averror_eof() }
        position += Int64(n)
        return Int32(n)
    }

    fileprivate func seek(_ offset: Int64, _ whence: Int32) -> Int64 {
        if whence & Int32(AVSEEK_SIZE) != 0 { return size }
        let newPosition: Int64
        switch whence & ~Int32(AVSEEK_FORCE) {
        case SEEK_SET: newPosition = offset
        case SEEK_CUR: newPosition = position + offset
        case SEEK_END: newPosition = size + offset
        default: return Int64(reel_averror(EINVAL))
        }
        guard newPosition >= 0 else { return Int64(reel_averror(EINVAL)) }
        position = newPosition
        return newPosition
    }
}

private func fileIORead(_ opaque: UnsafeMutableRawPointer?, _ buf: UnsafeMutablePointer<UInt8>?, _ size: Int32) -> Int32 {
    guard let opaque, let buf else { return reel_averror(EINVAL) }
    return Unmanaged<FileIO>.fromOpaque(opaque).takeUnretainedValue().read(buf, Int(size))
}

private func fileIOSeek(_ opaque: UnsafeMutableRawPointer?, _ offset: Int64, _ whence: Int32) -> Int64 {
    guard let opaque else { return Int64(reel_averror(EINVAL)) }
    return Unmanaged<FileIO>.fromOpaque(opaque).takeUnretainedValue().seek(offset, whence)
}

/// AVFormatContext interrupt callback: lets `FileIO.abort()` unblock av_read_frame.
func fileIOInterrupt(_ opaque: UnsafeMutableRawPointer?) -> Int32 {
    guard let opaque else { return 0 }
    return Unmanaged<FileIO>.fromOpaque(opaque).takeUnretainedValue().isAborted ? 1 : 0
}
