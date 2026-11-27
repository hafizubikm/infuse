import Foundation

/// Dolby Vision decoder configuration records (the dvcC / dvvC / dvwC sample-description
/// extension atoms of ETSI / Dolby's "Dolby Vision streams within the ISO base media file format").
enum DolbyVision {
    /// How Reel renders a Dolby Vision stream.
    enum Mode: Equatable {
        /// Native Dolby Vision (profiles 5, 8.x, 10.x): `dvh1`/`dav1` + configuration atom, RPU kept.
        case native
        /// Dual-layer profile 7: drop enhancement layer + RPU and play the HDR10 base layer.
        case baseLayerHDR10
        /// No usable compatible base layer and native DV failed (should not normally happen).
        case unsupported
    }

    /// Profile 7 (Blu-ray, BL+EL+RPU) plays as HDR10; everything else natively.
    static func mode(for config: DolbyVisionConfig) -> Mode {
        switch config.profile {
        case 7: return .baseLayerHDR10
        case 4: return .baseLayerHDR10          // legacy dual-layer, same treatment
        case 5, 8, 9, 10: return .native
        default: return config.blPresent && config.blSignalCompatibilityID != 0 ? .baseLayerHDR10 : .native
        }
    }

    /// Atom type for the configuration record: dvcC (profile ≤ 7), dvvC (8–10), dvwC (> 10).
    static func atomType(for config: DolbyVisionConfig) -> String {
        switch config.profile {
        case 0...7: return "dvcC"
        case 8...10: return "dvvC"
        default: return "dvwC"
        }
    }

    /// The 24-byte DOVIDecoderConfigurationRecord.
    static func configurationRecord(_ c: DolbyVisionConfig) -> Data {
        var d = Data(count: 24)
        d[0] = c.versionMajor
        d[1] = c.versionMinor
        // dv_profile (7) | dv_level (6) | rpu_present (1) | el_present (1) | bl_present (1)
        let bits16 = (UInt16(c.profile & 0x7F) << 9) | (UInt16(c.level & 0x3F) << 3)
            | (c.rpuPresent ? 1 << 2 : 0) | (c.elPresent ? 1 << 1 : 0) | (c.blPresent ? 1 : 0)
        d[2] = UInt8(bits16 >> 8)
        d[3] = UInt8(bits16 & 0xFF)
        // dv_bl_signal_compatibility_id (4) | reserved (28)
        d[4] = (c.blSignalCompatibilityID & 0x0F) << 4
        return d
    }

    /// Parses a 24-byte (or longer) configuration record.
    static func parse(_ d: Data) -> DolbyVisionConfig? {
        guard d.count >= 5 else { return nil }
        let b = [UInt8](d.prefix(5))
        let bits16 = UInt16(b[2]) << 8 | UInt16(b[3])
        return DolbyVisionConfig(
            versionMajor: b[0], versionMinor: b[1],
            profile: UInt8(bits16 >> 9), level: UInt8((bits16 >> 3) & 0x3F),
            rpuPresent: bits16 & 0x4 != 0, elPresent: bits16 & 0x2 != 0, blPresent: bits16 & 0x1 != 0,
            blSignalCompatibilityID: b[4] >> 4)
    }

    /// Human-readable description of what is shown, for the info overlay.
    static func renderDescription(_ c: DolbyVisionConfig, mode: Mode) -> String {
        switch mode {
        case .native: return "Dolby Vision Profile \(c.profileString)"
        case .baseLayerHDR10: return "Dolby Vision Profile \(c.profileString) → playing HDR10 base layer"
        case .unsupported: return "Dolby Vision Profile \(c.profileString) (unsupported)"
        }
    }
}
