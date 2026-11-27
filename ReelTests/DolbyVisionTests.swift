import XCTest
@testable import Reel

final class DolbyVisionTests: XCTestCase {
    private func config(_ profile: UInt8, level: UInt8, compat: UInt8, el: Bool = false) -> DolbyVisionConfig {
        DolbyVisionConfig(profile: profile, level: level, rpuPresent: true, elPresent: el, blPresent: true,
                          blSignalCompatibilityID: compat)
    }

    func testProfile81RecordMatchesMKVToolNix() {
        // Bytes mkvmerge wrote into TestMedia/dv_p81.mkv's BlockAdditionMapping (dvvC).
        let expected = Data([0x01, 0x00, 0x10, 0x0D, 0x10] + [UInt8](repeating: 0, count: 19))
        let c = config(8, level: 1, compat: 1)
        XCTAssertEqual(DolbyVision.configurationRecord(c), expected)
        XCTAssertEqual(DolbyVision.atomType(for: c), "dvvC")
        XCTAssertEqual(DolbyVision.parse(expected), c)
    }

    func testAtomTypesAndModes() {
        XCTAssertEqual(DolbyVision.atomType(for: config(5, level: 6, compat: 0)), "dvcC")
        XCTAssertEqual(DolbyVision.atomType(for: config(7, level: 6, compat: 6, el: true)), "dvcC")
        XCTAssertEqual(DolbyVision.atomType(for: config(8, level: 6, compat: 4)), "dvvC")
        XCTAssertEqual(DolbyVision.atomType(for: config(10, level: 6, compat: 1)), "dvvC")

        XCTAssertEqual(DolbyVision.mode(for: config(5, level: 6, compat: 0)), .native)
        XCTAssertEqual(DolbyVision.mode(for: config(8, level: 6, compat: 1)), .native)
        XCTAssertEqual(DolbyVision.mode(for: config(8, level: 6, compat: 4)), .native)
        XCTAssertEqual(DolbyVision.mode(for: config(7, level: 6, compat: 6, el: true)), .baseLayerHDR10)
    }

    func testRoundTripAllFields() {
        for profile: UInt8 in [4, 5, 7, 8, 9, 10] {
            for level: UInt8 in [1, 6, 9, 13] {
                let c = DolbyVisionConfig(versionMajor: 1, versionMinor: 0, profile: profile, level: level,
                                          rpuPresent: true, elPresent: profile == 7, blPresent: true,
                                          blSignalCompatibilityID: profile == 5 ? 0 : 1)
                XCTAssertEqual(DolbyVision.parse(DolbyVision.configurationRecord(c)), c)
            }
        }
    }

    func testRenderDescriptions() {
        let p7 = config(7, level: 6, compat: 6, el: true)
        XCTAssertEqual(DolbyVision.renderDescription(p7, mode: .baseLayerHDR10),
                       "Dolby Vision Profile 7 → playing HDR10 base layer")
        XCTAssertEqual(DolbyVision.renderDescription(config(8, level: 6, compat: 1), mode: .native),
                       "Dolby Vision Profile 8.1")
    }
}
