import XCTest
@testable import Reel

final class FormattingTests: XCTestCase {
    func testTime() {
        XCTAssertEqual(Formatting.time(0), "0:00")
        XCTAssertEqual(Formatting.time(42.9), "0:42")
        XCTAssertEqual(Formatting.time(725), "12:05")
        XCTAssertEqual(Formatting.time(6723), "1:52:03")
        XCTAssertEqual(Formatting.time(nil), "--:--")
        XCTAssertEqual(Formatting.time(.nan), "--:--")
    }

    func testBitRateAndFrameRate() {
        XCTAssertEqual(Formatting.bitRate(68_400_000), "68.4 Mb/s")
        XCTAssertEqual(Formatting.bitRate(640_000), "640 kb/s")
        XCTAssertNil(Formatting.bitRate(0))
        XCTAssertEqual(Formatting.frameRate(24000.0 / 1001.0), "23.976 fps")
        XCTAssertEqual(Formatting.frameRate(25), "25 fps")
        XCTAssertEqual(Formatting.frameRate(60000.0 / 1001.0), "59.94 fps")
    }

    func testResolutionClass() {
        XCTAssertEqual(Formatting.resolutionClass(width: 3840, height: 2160), "4K")
        XCTAssertEqual(Formatting.resolutionClass(width: 3840, height: 1600), "4K")
        XCTAssertEqual(Formatting.resolutionClass(width: 1920, height: 1080), "1080p")
        XCTAssertEqual(Formatting.resolutionClass(width: 1920, height: 800), "1080p")
        XCTAssertEqual(Formatting.resolutionClass(width: 1280, height: 720), "720p")
        XCTAssertEqual(Formatting.resolutionClass(width: 720, height: 480), "SD")
    }

    func testDolbyVisionProfileStrings() {
        func dv(_ profile: UInt8, _ compat: UInt8) -> DolbyVisionConfig {
            DolbyVisionConfig(profile: profile, level: 6, rpuPresent: true, elPresent: profile == 7,
                              blPresent: true, blSignalCompatibilityID: compat)
        }
        XCTAssertEqual(dv(5, 0).profileString, "5")
        XCTAssertEqual(dv(7, 6).profileString, "7")
        XCTAssertEqual(dv(8, 1).profileString, "8.1")
        XCTAssertEqual(dv(8, 4).profileString, "8.4")
        XCTAssertEqual(dv(10, 1).profileString, "10.1")
        XCTAssertTrue(dv(7, 6).isDualLayer)
        XCTAssertFalse(dv(8, 1).isDualLayer)
    }

    func testTrackMenuTitles() {
        var s = StreamInfo(index: 1, kind: .audio, codecName: "eac3", codecDisplayName: "E-AC-3", language: "eng")
        s.audio = AudioDetails(sampleRate: 48000, channels: 6, channelLayout: "5.1(side)", isAtmos: true)
        XCTAssertEqual(TrackLabels.audioFormat(s), "E-AC-3 5.1 Atmos")
        XCTAssertTrue(TrackLabels.menuTitle(s).hasSuffix("E-AC-3 5.1 Atmos"))

        var dts = StreamInfo(index: 2, kind: .audio, codecName: "dts", codecDisplayName: "DTS", profileName: "DTS-HD MA + DTS:X")
        dts.audio = AudioDetails(sampleRate: 48000, channels: 8, channelLayout: "7.1", isDTSX: true)
        XCTAssertEqual(TrackLabels.audioFormat(dts), "DTS-HD MA 7.1 DTS:X")
    }
}
