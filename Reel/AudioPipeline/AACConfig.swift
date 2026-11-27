import Foundation

/// AAC helpers: ADTS header parsing (MPEG-TS carries AAC as ADTS), AudioSpecificConfig
/// construction, and the ESDS magic cookie Core Audio expects for kAudioFormatMPEG4AAC.
enum AACConfig {
    static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    struct ADTSHeader: Equatable {
        var objectType: Int          // 1 = AAC Main, 2 = AAC LC, ...
        var sampleRateIndex: Int
        var channelConfig: Int
        var headerLength: Int        // 7, or 9 with CRC
        var frameLength: Int         // including header

        var sampleRate: Int? { sampleRateIndex < AACConfig.sampleRates.count ? AACConfig.sampleRates[sampleRateIndex] : nil }
    }

    static func parseADTS(_ d: UnsafeRawBufferPointer) -> ADTSHeader? {
        guard d.count >= 7, d[0] == 0xFF, d[1] & 0xF0 == 0xF0 else { return nil }
        let protectionAbsent = d[1] & 0x01
        let profile = Int(d[2] >> 6)                    // object type - 1
        let srIndex = Int((d[2] >> 2) & 0x0F)
        let channelConfig = Int((d[2] & 0x01) << 2 | (d[3] >> 6))
        let frameLength = Int(d[3] & 0x03) << 11 | Int(d[4]) << 3 | Int(d[5] >> 5)
        let headerLength = protectionAbsent == 1 ? 7 : 9
        guard frameLength >= headerLength else { return nil }
        return ADTSHeader(objectType: profile + 1, sampleRateIndex: srIndex, channelConfig: channelConfig,
                          headerLength: headerLength, frameLength: frameLength)
    }

    /// Two-byte AudioSpecificConfig for an ADTS stream.
    static func audioSpecificConfig(_ h: ADTSHeader) -> [UInt8] {
        let v = (h.objectType << 11) | (h.sampleRateIndex << 7) | (h.channelConfig << 3)
        return [UInt8(v >> 8), UInt8(v & 0xFF)]
    }

    /// Wraps an AudioSpecificConfig in an MPEG-4 ES_Descriptor (the "esds" payload).
    static func esds(audioSpecificConfig asc: [UInt8], bitRate: Int = 0) -> [UInt8] {
        func descriptor(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
            // Size in the 4-byte expandable form Core Audio accepts.
            let n = body.count
            return [tag, UInt8(0x80 | ((n >> 21) & 0x7F)), UInt8(0x80 | ((n >> 14) & 0x7F)),
                    UInt8(0x80 | ((n >> 7) & 0x7F)), UInt8(n & 0x7F)] + body
        }
        let br = UInt32(clamping: bitRate)
        let brBytes = [UInt8(br >> 24), UInt8((br >> 16) & 0xFF), UInt8((br >> 8) & 0xFF), UInt8(br & 0xFF)]
        let decoderSpecificInfo = descriptor(0x05, asc)
        let decoderConfig = descriptor(0x04,
            [0x40,                 // objectTypeIndication: MPEG-4 Audio
             0x15,                 // streamType = audio (5) << 2 | upStream 0 | reserved 1
             0x00, 0x00, 0x00]     // bufferSizeDB
            + brBytes + brBytes    // maxBitrate, avgBitrate
            + decoderSpecificInfo)
        let slConfig = descriptor(0x06, [0x02])
        return descriptor(0x03, [0x00, 0x00, 0x00] + decoderConfig + slConfig)  // ES_ID 0, flags 0
    }
}
