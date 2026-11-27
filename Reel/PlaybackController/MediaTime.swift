import Foundation
import CoreMedia
import CFFmpeg

/// Converts a stream's timestamps to "media time": a CMTime where 0 is the start of the file.
/// (Transport streams often start at an arbitrary PTS; that offset is removed here.)
struct StreamTimeConverter {
    let timeBase: AVRational
    /// Container start time in AV_TIME_BASE (µs) units.
    let startTime: Int64

    private var startCM: CMTime { CMTime(value: startTime, timescale: 1_000_000) }

    func time(_ ts: Int64) -> CMTime {
        let t = CMTime(value: ts * Int64(timeBase.num), timescale: timeBase.den)
        return startTime == 0 ? t : CMTimeSubtract(t, startCM)
    }

    func duration(_ d: Int64) -> CMTime {
        d > 0 ? CMTime(value: d * Int64(timeBase.num), timescale: timeBase.den) : .invalid
    }

    func seconds(_ ts: Int64) -> Double { time(ts).seconds }
}

enum SampleBufferFactory {
    /// Copies `bytes` into a new CMBlockBuffer.
    static func blockBuffer(_ bytes: UnsafeRawBufferPointer) -> CMBlockBuffer? {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block,
              CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count) == noErr
        else { return nil }
        return block
    }

    static func blockBuffer(_ bytes: [UInt8]) -> CMBlockBuffer? {
        bytes.withUnsafeBytes { blockBuffer($0) }
    }

    /// Sets a boolean sample attachment (e.g. NotSync, DoNotDisplay) on the first sample.
    static func setSampleAttachment(_ sb: CMSampleBuffer, _ key: CFString, _ value: Bool) {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
              CFArrayGetCount(array) > 0 else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
        let boolean: CFBoolean = value ? kCFBooleanTrue! : kCFBooleanFalse!
        CFDictionarySetValue(dict, Unmanaged.passUnretained(key).toOpaque(),
                             Unmanaged.passUnretained(boolean).toOpaque())
    }
}
