import Foundation
import CFFmpeg

/// A loudspeaker position, independent of FFmpeg's and Core Audio's channel enums.
/// Used to build Core Audio channel layouts and (milestone 7) to place virtual speakers.
enum Speaker: String, CaseIterable, Sendable {
    case frontLeft, frontRight, center, lfe
    /// Ls / Rs: the surround pair in 5.1, the side pair in 7.1.
    case surroundLeft, surroundRight
    /// Rls / Rrs: the rear pair of 7.1.
    case rearLeft, rearRight
    case rearCenter
    case frontLeftOfCenter, frontRightOfCenter
    case topCenter, topFrontLeft, topFrontCenter, topFrontRight
    case topBackLeft, topBackCenter, topBackRight, topSideLeft, topSideRight
    case wideLeft, wideRight
    case lfe2
    case unknown

    var isLFE: Bool { self == .lfe || self == .lfe2 }

    /// Horizontal angle in degrees (0 = straight ahead, negative = left), ITU-R BS.775 style.
    var azimuth: Double {
        switch self {
        case .center, .topCenter, .topFrontCenter, .lfe, .lfe2, .unknown: return 0
        case .frontLeft: return -30
        case .frontRight: return 30
        case .frontLeftOfCenter: return -15
        case .frontRightOfCenter: return 15
        case .wideLeft: return -60
        case .wideRight: return 60
        case .surroundLeft, .topSideLeft: return -110
        case .surroundRight, .topSideRight: return 110
        case .rearLeft, .topBackLeft: return -150
        case .rearRight, .topBackRight: return 150
        case .rearCenter, .topBackCenter: return 180
        case .topFrontLeft: return -45
        case .topFrontRight: return 45
        }
    }

    /// Vertical angle in degrees (height channels).
    var elevation: Double {
        switch self {
        case .topCenter: return 90
        case .topFrontLeft, .topFrontCenter, .topFrontRight, .topBackLeft, .topBackCenter, .topBackRight,
             .topSideLeft, .topSideRight: return 45
        default: return 0
        }
    }
}

enum SpeakerLayout {
    /// The speakers of an FFmpeg channel layout, in the layout's channel order.
    ///
    /// FFmpeg names the surround pair of 5.1 either BL/BR ("5.1") or SL/SR ("5.1(side)"), and
    /// in 7.1 uses SL/SR for the sides and BL/BR for the rears. Core Audio (and listeners)
    /// treat the 5.1 pair as Ls/Rs either way, so map by role, not by name.
    static func speakers(for layout: AVChannelLayout) -> [Speaker] {
        var layout = layout
        let count = Int(layout.nb_channels)
        guard count > 0 else { return [] }
        var defaulted = AVChannelLayout()
        if layout.order == AV_CHANNEL_ORDER_UNSPEC {
            av_channel_layout_default(&defaulted, Int32(count))
            layout = defaulted
        }
        var channels: [AVChannel] = []
        for i in 0..<count {
            channels.append(av_channel_layout_channel_from_index(&layout, UInt32(i)))
        }
        let hasSide = channels.contains(AV_CHAN_SIDE_LEFT) || channels.contains(AV_CHAN_SIDE_RIGHT)
        let hasBack = channels.contains(AV_CHAN_BACK_LEFT) || channels.contains(AV_CHAN_BACK_RIGHT)
        return channels.map { ch in
            switch ch {
            case AV_CHAN_FRONT_LEFT, AV_CHAN_STEREO_LEFT: return .frontLeft
            case AV_CHAN_FRONT_RIGHT, AV_CHAN_STEREO_RIGHT: return .frontRight
            case AV_CHAN_FRONT_CENTER: return .center
            case AV_CHAN_LOW_FREQUENCY: return .lfe
            case AV_CHAN_LOW_FREQUENCY_2: return .lfe2
            case AV_CHAN_SIDE_LEFT: return .surroundLeft
            case AV_CHAN_SIDE_RIGHT: return .surroundRight
            case AV_CHAN_BACK_LEFT: return hasSide ? .rearLeft : .surroundLeft
            case AV_CHAN_BACK_RIGHT: return hasSide ? .rearRight : .surroundRight
            case AV_CHAN_BACK_CENTER: return .rearCenter
            case AV_CHAN_FRONT_LEFT_OF_CENTER: return .frontLeftOfCenter
            case AV_CHAN_FRONT_RIGHT_OF_CENTER: return .frontRightOfCenter
            case AV_CHAN_SURROUND_DIRECT_LEFT: return hasSide || hasBack ? .rearLeft : .surroundLeft
            case AV_CHAN_SURROUND_DIRECT_RIGHT: return hasSide || hasBack ? .rearRight : .surroundRight
            case AV_CHAN_WIDE_LEFT: return .wideLeft
            case AV_CHAN_WIDE_RIGHT: return .wideRight
            case AV_CHAN_TOP_CENTER: return .topCenter
            case AV_CHAN_TOP_FRONT_LEFT: return .topFrontLeft
            case AV_CHAN_TOP_FRONT_CENTER: return .topFrontCenter
            case AV_CHAN_TOP_FRONT_RIGHT: return .topFrontRight
            case AV_CHAN_TOP_BACK_LEFT: return .topBackLeft
            case AV_CHAN_TOP_BACK_CENTER: return .topBackCenter
            case AV_CHAN_TOP_BACK_RIGHT: return .topBackRight
            case AV_CHAN_TOP_SIDE_LEFT: return .topSideLeft
            case AV_CHAN_TOP_SIDE_RIGHT: return .topSideRight
            default: return .unknown
            }
        }
    }
}
