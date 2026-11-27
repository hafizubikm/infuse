import XCTest
@testable import Reel

final class NALUtilsTests: XCTestCase {
    private func withBytes<T>(_ bytes: [UInt8], _ body: (UnsafeRawBufferPointer) -> T) -> T {
        bytes.withUnsafeBytes(body)
    }

    func testAnnexBToLengthPrefixed() {
        // 4-byte start code + SPS(7), 3-byte start code + PPS(8), AUD(9), IDR(5) with trailing zero
        let annexB: [UInt8] = [0, 0, 0, 1, 0x67, 0xAA, 0xBB,
                               0, 0, 1, 0x68, 0xCC,
                               0, 0, 0, 1, 0x09, 0xF0,
                               0, 0, 1, 0x65, 0x11, 0x22, 0x33, 0x00]
        withBytes(annexB) { d in
            XCTAssertTrue(NALUtils.isAnnexB(d))
            XCTAssertEqual(NALUtils.annexBUnits(d).count, 4)
            let out = NALUtils.annexBToLengthPrefixed(d, codec: .h264) { $0 == NALUtils.h264AUD }
            XCTAssertEqual(out, [0, 0, 0, 3, 0x67, 0xAA, 0xBB,
                                 0, 0, 0, 2, 0x68, 0xCC,
                                 0, 0, 0, 4, 0x65, 0x11, 0x22, 0x33])
            let ps = NALUtils.parameterSets(annexB: d, codec: .h264)
            XCTAssertEqual(ps, [[0x67, 0xAA, 0xBB], [0x68, 0xCC]])
        }
    }

    func testHEVCParameterSetsAndFiltering() {
        // VPS(32)=0x40, SPS(33)=0x42, PPS(34)=0x44, slice(1)=0x02, RPU(62)=0x7C, EL(63)=0x7E
        let annexB: [UInt8] = [0, 0, 0, 1, 0x40, 0x01, 0, 0, 1, 0x42, 0x01, 0x02,
                               0, 0, 1, 0x44, 0x01, 0, 0, 1, 0x02, 0x01, 0x99]
        withBytes(annexB) { d in
            XCTAssertEqual(NALUtils.parameterSets(annexB: d, codec: .hevc).map { $0[0] }, [0x40, 0x42, 0x44])
        }
        // Length-prefixed (2-byte lengths): slice, RPU, EL
        let lp: [UInt8] = [0, 3, 0x02, 0x01, 0xAA, 0, 2, 0x7C, 0x01, 0, 2, 0x7E, 0x01]
        withBytes(lp) { d in
            XCTAssertEqual(NALUtils.lengthPrefixedUnits(d, lengthSize: 2)?.count, 3)
            let filtered = NALUtils.filterLengthPrefixed(d, lengthSize: 2, codec: .hevc) {
                $0 == NALUtils.hevcDolbyVisionRPU || $0 == NALUtils.hevcDolbyVisionEL
            }
            XCTAssertEqual(filtered, [0, 0, 0, 3, 0x02, 0x01, 0xAA])
            XCTAssertNil(NALUtils.lengthPrefixedUnits(d, lengthSize: 4))
        }
        // Nothing to drop with 4-byte lengths → nil (use original bytes)
        let lp4: [UInt8] = [0, 0, 0, 2, 0x02, 0x01]
        withBytes(lp4) { d in
            XCTAssertNil(NALUtils.filterLengthPrefixed(d, lengthSize: 4, codec: .hevc) { $0 == 62 })
        }
    }

    func testLengthSizeFromRecords() {
        var avcC = [UInt8](repeating: 0, count: 8); avcC[0] = 1; avcC[4] = 0xFF
        var hvcC = [UInt8](repeating: 0, count: 23); hvcC[0] = 1; hvcC[21] = 0x0F
        withBytes(avcC) { XCTAssertEqual(NALUtils.lengthSize(decoderConfigurationRecord: $0, codec: .h264), 4) }
        withBytes(hvcC) { XCTAssertEqual(NALUtils.lengthSize(decoderConfigurationRecord: $0, codec: .hevc), 4) }
    }
}

final class AACConfigTests: XCTestCase {
    func testADTSToAudioSpecificConfigAndESDS() throws {
        // ADTS: AAC LC, 48 kHz (index 3), 2 channels, no CRC, frame length 0x100
        let frameLength = 0x100
        let adts: [UInt8] = [0xFF, 0xF1, 0x4C, 0x80 | UInt8((frameLength >> 11) & 0x3),
                             UInt8((frameLength >> 3) & 0xFF), UInt8((frameLength & 0x7) << 5) | 0x1F, 0xFC]
        let h = try XCTUnwrap(adts.withUnsafeBytes { AACConfig.parseADTS($0) })
        XCTAssertEqual(h.objectType, 2)
        XCTAssertEqual(h.sampleRate, 48000)
        XCTAssertEqual(h.channelConfig, 2)
        XCTAssertEqual(h.headerLength, 7)
        XCTAssertEqual(h.frameLength, frameLength)
        let asc = AACConfig.audioSpecificConfig(h)
        XCTAssertEqual(asc, [0x11, 0x90])   // well-known ASC for AAC-LC 48 kHz stereo

        let esds = AACConfig.esds(audioSpecificConfig: asc)
        XCTAssertEqual(esds.first, 0x03)
        XCTAssertTrue(esds.suffix(6).elementsEqual([0x06, 0x80, 0x80, 0x80, 0x01, 0x02]))
        XCTAssertNotNil(esds.firstRange(of: [0x05, 0x80, 0x80, 0x80, 0x02, 0x11, 0x90]))
    }

    func testRejectsNonADTS() {
        XCTAssertNil([UInt8](repeating: 0, count: 8).withUnsafeBytes { AACConfig.parseADTS($0) })
    }
}

final class HDRMetadataTests: XCTestCase {
    func testMasteringDisplayAndCLLPayloads() throws {
        let md = MasteringDisplay(
            red: ChromaticityPoint(x: 0.680, y: 0.320), green: ChromaticityPoint(x: 0.265, y: 0.690),
            blue: ChromaticityPoint(x: 0.150, y: 0.060), whitePoint: ChromaticityPoint(x: 0.3127, y: 0.3290),
            minLuminance: 0.0001, maxLuminance: 1000)
        let data = try XCTUnwrap(HDRMetadata.masteringDisplayColorVolume(md))
        XCTAssertEqual(data.count, 24)
        // x265 notation: G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1)
        let expected: [UInt16] = [13250, 34500, 7500, 3000, 34000, 16000, 15635, 16450]
        for (i, v) in expected.enumerated() {
            XCTAssertEqual(UInt16(data[2 * i]) << 8 | UInt16(data[2 * i + 1]), v, "field \(i)")
        }
        XCTAssertEqual(Array(data[16..<24]), [0x00, 0x98, 0x96, 0x80, 0x00, 0x00, 0x00, 0x01])
        XCTAssertEqual(HDRMetadata.contentLightLevelInfo(ContentLightLevel(maxCLL: 1000, maxFALL: 400)),
                       Data([0x03, 0xE8, 0x01, 0x90]))
        XCTAssertNil(HDRMetadata.masteringDisplayColorVolume(MasteringDisplay()))
    }
}
