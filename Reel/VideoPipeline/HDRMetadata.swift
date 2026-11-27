import Foundation

/// Serialises HDR10 static metadata into the big-endian payloads CoreMedia expects for
/// kCMFormatDescriptionExtension_MasteringDisplayColorVolume (ST 2086, as in the HEVC SEI /
/// ISO "mdcv" box) and kCMFormatDescriptionExtension_ContentLightLevelInfo ("clli" box).
enum HDRMetadata {
    /// 24 bytes: primaries G, B, R (x, y each in 0.00002 units), white point, then max and min
    /// luminance in 0.0001 cd/m². Returns nil unless primaries, white point and luminance are known.
    static func masteringDisplayColorVolume(_ md: MasteringDisplay) -> Data? {
        guard let r = md.red, let g = md.green, let b = md.blue, let wp = md.whitePoint,
              let maxL = md.maxLuminance, let minL = md.minLuminance else { return nil }
        var out = Data(capacity: 24)
        func u16(_ v: Double, scale: Double) {
            let x = UInt16(clamping: Int((v * scale).rounded()))
            out.append(UInt8(x >> 8)); out.append(UInt8(x & 0xFF))
        }
        func u32(_ v: Double, scale: Double) {
            let x = UInt32(clamping: Int64((v * scale).rounded()))
            out.append(contentsOf: [UInt8(x >> 24), UInt8((x >> 16) & 0xFF), UInt8((x >> 8) & 0xFF), UInt8(x & 0xFF)])
        }
        for p in [g, b, r] { u16(p.x, scale: 50000); u16(p.y, scale: 50000) }
        u16(wp.x, scale: 50000); u16(wp.y, scale: 50000)
        u32(maxL, scale: 10000)
        u32(minL, scale: 10000)
        return out
    }

    /// 4 bytes: MaxCLL, MaxFALL (cd/m²).
    static func contentLightLevelInfo(_ cll: ContentLightLevel) -> Data {
        let a = UInt16(clamping: cll.maxCLL), b = UInt16(clamping: cll.maxFALL)
        return Data([UInt8(a >> 8), UInt8(a & 0xFF), UInt8(b >> 8), UInt8(b & 0xFF)])
    }
}
