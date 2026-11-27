import Foundation
import AudioToolbox
import CoreMedia

/// Maps FFmpeg-ordered speakers to a Core Audio channel layout for decoded PCM.
///
/// Common layouts use standard tags (reordering samples where needed), so the spatializer and
/// every output device understand them; anything else gets explicit channel descriptions.
struct ChannelLayoutPlan {
    /// For each output channel, the index of the source channel to copy (nil = identity).
    let sourceIndexForOutput: [Int]?
    /// Bytes of the AudioChannelLayout (tag or channel descriptions).
    let layoutData: Data
    let channelCount: Int
    let name: String

    func reorder(_ interleaved: [Float]) -> [Float] {
        guard let map = sourceIndexForOutput else { return interleaved }
        let n = channelCount
        var out = [Float](repeating: 0, count: interleaved.count)
        interleaved.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var i = 0
                while i < src.count {
                    for c in 0..<n { dst[i + c] = src[i + map[c]] }
                    i += n
                }
            }
        }
        return out
    }
}

enum ChannelLayoutMapper {
    static func plan(for speakers: [Speaker]) -> ChannelLayoutPlan {
        let s = speakers
        // Standard layouts, in Core Audio's channel order for the tag.
        let standards: [(AudioChannelLayoutTag, [Speaker], String)] = [
            (kAudioChannelLayoutTag_Mono, [.center], "Mono"),
            (kAudioChannelLayoutTag_Stereo, [.frontLeft, .frontRight], "Stereo"),
            (kAudioChannelLayoutTag_MPEG_5_0_A, [.frontLeft, .frontRight, .center, .surroundLeft, .surroundRight], "5.0"),
            (kAudioChannelLayoutTag_MPEG_5_1_A, [.frontLeft, .frontRight, .center, .lfe, .surroundLeft, .surroundRight], "5.1"),
            (kAudioChannelLayoutTag_MPEG_7_1_C, [.frontLeft, .frontRight, .center, .lfe, .surroundLeft, .surroundRight,
                                                 .rearLeft, .rearRight], "7.1"),
        ]
        for (tag, order, name) in standards where order.count == s.count && Set(order) == Set(s) {
            let map = order.map { s.firstIndex(of: $0)! }
            let identity = map == Array(0..<map.count)
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = tag
            let data = withUnsafeBytes(of: &layout) { Data($0) }
            return ChannelLayoutPlan(sourceIndexForOutput: identity ? nil : map, layoutData: data,
                                     channelCount: s.count, name: name)
        }
        return ChannelLayoutPlan(sourceIndexForOutput: nil, layoutData: descriptionsLayout(s),
                                 channelCount: s.count, name: "\(s.count)ch")
    }

    static func label(_ s: Speaker) -> AudioChannelLabel {
        switch s {
        case .frontLeft: return kAudioChannelLabel_Left
        case .frontRight: return kAudioChannelLabel_Right
        case .center: return kAudioChannelLabel_Center
        case .lfe: return kAudioChannelLabel_LFEScreen
        case .lfe2: return kAudioChannelLabel_LFE2
        case .surroundLeft: return kAudioChannelLabel_LeftSurround
        case .surroundRight: return kAudioChannelLabel_RightSurround
        case .rearLeft: return kAudioChannelLabel_RearSurroundLeft
        case .rearRight: return kAudioChannelLabel_RearSurroundRight
        case .rearCenter: return kAudioChannelLabel_CenterSurround
        case .frontLeftOfCenter: return kAudioChannelLabel_LeftCenter
        case .frontRightOfCenter: return kAudioChannelLabel_RightCenter
        case .wideLeft: return kAudioChannelLabel_LeftWide
        case .wideRight: return kAudioChannelLabel_RightWide
        case .topCenter: return kAudioChannelLabel_TopCenterSurround
        case .topFrontLeft: return kAudioChannelLabel_VerticalHeightLeft
        case .topFrontCenter: return kAudioChannelLabel_VerticalHeightCenter
        case .topFrontRight: return kAudioChannelLabel_VerticalHeightRight
        case .topBackLeft: return kAudioChannelLabel_TopBackLeft
        case .topBackCenter: return kAudioChannelLabel_TopBackCenter
        case .topBackRight: return kAudioChannelLabel_TopBackRight
        case .topSideLeft: return kAudioChannelLabel_LeftTopMiddle
        case .topSideRight: return kAudioChannelLabel_RightTopMiddle
        case .unknown: return kAudioChannelLabel_Unknown
        }
    }

    /// A kAudioChannelLayoutTag_UseChannelDescriptions layout listing every channel.
    private static func descriptionsLayout(_ speakers: [Speaker]) -> Data {
        let headerSize = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions)!
        let size = headerSize + max(1, speakers.count) * MemoryLayout<AudioChannelDescription>.stride
        var data = Data(count: max(size, MemoryLayout<AudioChannelLayout>.size))
        data.withUnsafeMutableBytes { raw in
            let layout = raw.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self)
            layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
            layout.pointee.mChannelBitmap = []
            layout.pointee.mNumberChannelDescriptions = UInt32(speakers.count)
            let descriptions = (raw.baseAddress! + headerSize).bindMemory(to: AudioChannelDescription.self, capacity: speakers.count)
            for (i, s) in speakers.enumerated() {
                descriptions[i] = AudioChannelDescription(mChannelLabel: label(s), mChannelFlags: [], mCoordinates: (0, 0, 0))
            }
        }
        return data
    }

    /// Interleaved Float32 LPCM format description with the given layout.
    static func pcmFormatDescription(sampleRate: Int, plan: ChannelLayoutPlan) throws -> CMAudioFormatDescription {
        let channels = UInt32(plan.channelCount)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        var fd: CMAudioFormatDescription?
        let status = plan.layoutData.withUnsafeBytes { layout in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: layout.count,
                layout: layout.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self),
                magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        }
        guard status == noErr, let fd else { throw AudioFormatError.coreAudio(status) }
        return fd
    }
}
