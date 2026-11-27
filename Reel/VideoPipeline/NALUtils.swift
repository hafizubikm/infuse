import Foundation

/// H.264/HEVC NAL unit helpers: Annex-B (start codes, as in MPEG-TS) ↔ length-prefixed
/// (as in MP4/MKV and as VideoToolbox expects), parameter-set extraction, NAL filtering.
enum NALUtils {
    enum Codec { case h264, hevc }

    static func nalType(_ firstByte: UInt8, codec: Codec) -> UInt8 {
        switch codec {
        case .h264: return firstByte & 0x1F
        case .hevc: return (firstByte >> 1) & 0x3F
        }
    }

    // H.264 NAL types
    static let h264SPS: UInt8 = 7
    static let h264PPS: UInt8 = 8
    static let h264AUD: UInt8 = 9
    // HEVC NAL types
    static let hevcVPS: UInt8 = 32
    static let hevcSPS: UInt8 = 33
    static let hevcPPS: UInt8 = 34
    static let hevcAUD: UInt8 = 35
    /// Dolby Vision RPU (UNSPEC62) and enhancement layer (UNSPEC63) NAL units.
    static let hevcDolbyVisionRPU: UInt8 = 62
    static let hevcDolbyVisionEL: UInt8 = 63

    /// True if the data starts with a 3- or 4-byte start code.
    static func isAnnexB(_ data: UnsafeRawBufferPointer) -> Bool {
        if data.count >= 4, data[0] == 0, data[1] == 0, data[2] == 0, data[3] == 1 { return true }
        if data.count >= 3, data[0] == 0, data[1] == 0, data[2] == 1 { return true }
        return false
    }

    /// Byte ranges of the NAL unit payloads (without start codes) in an Annex-B buffer.
    static func annexBUnits(_ data: UnsafeRawBufferPointer) -> [Range<Int>] {
        var starts: [Int] = []       // index of first payload byte
        var codeStarts: [Int] = []   // index of the start code (incl. leading zero of 4-byte codes)
        let n = data.count
        var i = 0
        while i + 2 < n {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                codeStarts.append(i > 0 && data[i - 1] == 0 ? i - 1 : i)
                starts.append(i + 3)
                i += 3
            } else {
                i += 1
            }
        }
        var units: [Range<Int>] = []
        for (k, s) in starts.enumerated() {
            var e = k + 1 < starts.count ? codeStarts[k + 1] : n
            // trailing_zero_8bits are not part of the NAL unit (a NAL unit never ends in 0x00)
            while e > s, data[e - 1] == 0 { e -= 1 }
            if e > s { units.append(s..<e) }
        }
        return units
    }

    /// Byte ranges of the NAL units in a length-prefixed buffer (`lengthSize` = 1, 2 or 4).
    /// Returns nil if the lengths don't add up (corrupt or not length-prefixed).
    static func lengthPrefixedUnits(_ data: UnsafeRawBufferPointer, lengthSize: Int) -> [Range<Int>]? {
        var units: [Range<Int>] = []
        var i = 0
        while i < data.count {
            guard i + lengthSize <= data.count else { return nil }
            var len = 0
            for b in 0..<lengthSize { len = (len << 8) | Int(data[i + b]) }
            i += lengthSize
            guard len > 0, i + len <= data.count else { return len == 0 ? units : nil }
            units.append(i..<(i + len))
            i += len
        }
        return units
    }

    /// Converts Annex-B to 4-byte length-prefixed NAL units, dropping types for which `drop` is true.
    static func annexBToLengthPrefixed(_ data: UnsafeRawBufferPointer, codec: Codec,
                                       drop: (UInt8) -> Bool = { _ in false }) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count + 16)
        for r in annexBUnits(data) where !drop(nalType(data[r.lowerBound], codec: codec)) {
            appendLengthPrefixed(&out, data, r)
        }
        return out
    }

    /// Re-emits a length-prefixed buffer as 4-byte length-prefixed units, dropping NAL types.
    /// Returns nil when nothing would change (so the caller can use the original bytes).
    static func filterLengthPrefixed(_ data: UnsafeRawBufferPointer, lengthSize: Int, codec: Codec,
                                     drop: (UInt8) -> Bool) -> [UInt8]? {
        guard let units = lengthPrefixedUnits(data, lengthSize: lengthSize) else { return nil }
        let keep = units.filter { !drop(nalType(data[$0.lowerBound], codec: codec)) }
        if keep.count == units.count && lengthSize == 4 { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        for r in keep { appendLengthPrefixed(&out, data, r) }
        return out
    }

    /// Parameter sets (SPS/PPS, plus VPS for HEVC) found in Annex-B data, in VPS, SPS, PPS order.
    static func parameterSets(annexB data: UnsafeRawBufferPointer, codec: Codec) -> [[UInt8]] {
        let wanted: [UInt8] = codec == .h264 ? [h264SPS, h264PPS] : [hevcVPS, hevcSPS, hevcPPS]
        var byType: [UInt8: [[UInt8]]] = [:]
        for r in annexBUnits(data) {
            let t = nalType(data[r.lowerBound], codec: codec)
            if wanted.contains(t) {
                let unit = Array(data[r])
                if byType[t]?.contains(unit) != true { byType[t, default: []].append(unit) }
            }
        }
        return wanted.flatMap { byType[$0] ?? [] }
    }

    /// NAL length size from an avcC (byte 4) or hvcC (byte 21) record.
    static func lengthSize(decoderConfigurationRecord rec: UnsafeRawBufferPointer, codec: Codec) -> Int? {
        switch codec {
        case .h264:
            guard rec.count >= 7, rec[0] == 1 else { return nil }
            return Int(rec[4] & 0x03) + 1
        case .hevc:
            guard rec.count >= 23, rec[0] == 1 else { return nil }
            return Int(rec[21] & 0x03) + 1
        }
    }

    private static func appendLengthPrefixed(_ out: inout [UInt8], _ data: UnsafeRawBufferPointer, _ r: Range<Int>) {
        let len = UInt32(r.count)
        out.append(UInt8(len >> 24)); out.append(UInt8((len >> 16) & 0xFF))
        out.append(UInt8((len >> 8) & 0xFF)); out.append(UInt8(len & 0xFF))
        out.append(contentsOf: data[r])
    }
}
