import Foundation
import AudioToolbox
import CoreMedia
import CFFmpeg

/// A compressed audio format that AVSampleBufferAudioRenderer decodes itself.
struct PassthroughAudioFormat {
    let formatDescription: CMAudioFormatDescription
    let framesPerPacket: Int
    let sampleRate: Double
    /// MPEG-TS AAC arrives as ADTS frames; the 7/9-byte header is stripped from every packet.
    let stripsADTSHeader: Bool
    let description: String
}

enum AudioFormatError: Error, CustomStringConvertible {
    case notPassthrough(String)
    case missingConfig
    case coreAudio(OSStatus)

    var description: String {
        switch self {
        case .notPassthrough(let c): return "\(c) needs FFmpeg decoding"
        case .missingConfig: return "The audio stream has no decoder configuration"
        case .coreAudio(let s): return "Core Audio rejected the audio format (\(s))"
        }
    }
}

enum AudioFormatFactory {
    /// Codecs macOS decodes natively (incl. Dolby Atmos in E-AC-3 JOC).
    static func supportsPassthrough(codecID: AVCodecID) -> Bool {
        codecID == AV_CODEC_ID_AAC || codecID == AV_CODEC_ID_AC3 || codecID == AV_CODEC_ID_EAC3
    }

    /// - Parameter firstPacket: needed for AAC without extradata (ADTS in MPEG-TS).
    static func makePassthrough(par: AVCodecParameters, firstPacket: Packet?) throws -> PassthroughAudioFormat {
        let sampleRate = Double(par.sample_rate)
        let channels = UInt32(max(1, par.ch_layout.nb_channels))

        switch par.codec_id {
        case AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3:
            let isEAC3 = par.codec_id == AV_CODEC_ID_EAC3
            var asbd = AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: isEAC3 ? kAudioFormatEnhancedAC3 : kAudioFormatAC3,
                mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1536, mBytesPerFrame: 0,
                mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
            let fd = try create(&asbd, cookie: nil)
            return PassthroughAudioFormat(formatDescription: fd, framesPerPacket: 1536, sampleRate: sampleRate,
                                          stripsADTSHeader: false, description: isEAC3 ? "E-AC-3" : "AC-3")

        case AV_CODEC_ID_AAC:
            var asc: [UInt8]
            var stripsADTS = false
            if let extradata = par.extradata, par.extradata_size >= 2 {
                asc = Array(UnsafeRawBufferPointer(start: extradata, count: Int(par.extradata_size)))
            } else if let packet = firstPacket, let header = AACConfig.parseADTS(packet.bytes) {
                asc = AACConfig.audioSpecificConfig(header)
                stripsADTS = true
            } else {
                throw AudioFormatError.missingConfig
            }
            let cookie = AACConfig.esds(audioSpecificConfig: asc, bitRate: Int(par.bit_rate))
            var asbd = AudioStreamBasicDescription()
            asbd.mFormatID = kAudioFormatMPEG4AAC
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = cookie.withUnsafeBytes {
                AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, UInt32($0.count), $0.baseAddress, &size, &asbd)
            }
            if status != noErr || asbd.mSampleRate == 0 {
                // Fall back to what FFmpeg reported (AAC-LC, 1024 frames per packet).
                asbd = AudioStreamBasicDescription(
                    mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
                    mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                    mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
            }
            if asbd.mFramesPerPacket == 0 { asbd.mFramesPerPacket = 1024 }
            let fd = try create(&asbd, cookie: cookie)
            return PassthroughAudioFormat(formatDescription: fd, framesPerPacket: Int(asbd.mFramesPerPacket),
                                          sampleRate: asbd.mSampleRate, stripsADTSHeader: stripsADTS,
                                          description: asbd.mFormatID == kAudioFormatMPEG4AAC ? "AAC" : "HE-AAC")

        default:
            throw AudioFormatError.notPassthrough(ffString(avcodec_get_name(par.codec_id)) ?? "?")
        }
    }

    private static func create(_ asbd: inout AudioStreamBasicDescription, cookie: [UInt8]?) throws -> CMAudioFormatDescription {
        var fd: CMAudioFormatDescription?
        let status: OSStatus
        if let cookie {
            status = cookie.withUnsafeBytes {
                CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                               magicCookieSize: $0.count, magicCookie: $0.baseAddress,
                                               extensions: nil, formatDescriptionOut: &fd)
            }
        } else {
            status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                                    magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                    formatDescriptionOut: &fd)
        }
        guard status == noErr, let fd else { throw AudioFormatError.coreAudio(status) }
        return fd
    }
}
