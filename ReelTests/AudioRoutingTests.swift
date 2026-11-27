import XCTest
@testable import Reel

final class AudioRoutingTests: XCTestCase {
    let airPods = AudioOutputDevice(uid: "AA-BB-CC:output", name: "AirPods Pro", transport: .bluetooth)
    let renamedAirPods = AudioOutputDevice(uid: "DD-EE:output", name: "Living Room Buds", modelUID: "2014 4c", transport: .bluetooth)
    let sony = AudioOutputDevice(uid: "11-22-33:output", name: "WH-1000XM5", modelUID: "0d58 54c", transport: .bluetooth)
    let speakers = AudioOutputDevice(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers", transport: .builtIn)
    let jack = AudioOutputDevice(uid: "BuiltInHeadphoneOutputDevice", name: "External Headphones", transport: .builtIn,
                                 isHeadphonePort: true)
    let tv = AudioOutputDevice(uid: "hdmi-1", name: "LG TV", transport: .hdmi, outputChannels: 8)
    let usbHeadset = AudioOutputDevice(uid: "usb-1", name: "USB Audio Headset", transport: .usb)
    let interface = AudioOutputDevice(uid: "usb-2", name: "Scarlett 2i2", transport: .usb)

    func testDeviceClassification() {
        XCTAssertEqual(airPods.kind, .appleHeadphones)
        XCTAssertEqual(renamedAirPods.kind, .appleHeadphones, "Apple's Bluetooth vendor ID in the model UID")
        XCTAssertEqual(AudioOutputDevice(uid: "b", name: "Beats Studio Pro", transport: .bluetooth).kind, .appleHeadphones)
        XCTAssertEqual(sony.kind, .otherHeadphones, "Sony's vendor ID 0x054C is not Apple's 0x004C")
        XCTAssertEqual(speakers.kind, .builtInSpeakers)
        XCTAssertEqual(jack.kind, .otherHeadphones)
        XCTAssertEqual(tv.kind, .external)
        XCTAssertEqual(usbHeadset.kind, .otherHeadphones)
        XCTAssertEqual(interface.kind, .external)
        XCTAssertEqual(jack.transportLabel, "Headphone jack")
    }

    func testPolicy() {
        func decide(_ mode: AudioMode, _ device: AudioOutputDevice?, _ remembered: Bool? = nil) -> AudioRoutePolicy.Decision {
            AudioRoutePolicy.decide(mode: mode, device: device, remembered: remembered)
        }
        XCTAssertEqual(decide(.auto, airPods), .init(rendering: .spatial, offerVirtualSurround: false))
        XCTAssertEqual(decide(.auto, speakers), .init(rendering: .spatial, offerVirtualSurround: false))
        XCTAssertEqual(decide(.auto, tv), .init(rendering: .spatial, offerVirtualSurround: false))
        XCTAssertEqual(decide(.auto, nil), .init(rendering: .spatial, offerVirtualSurround: false))
        XCTAssertEqual(decide(.auto, sony), .init(rendering: .spatial, offerVirtualSurround: true))
        XCTAssertEqual(decide(.auto, sony, true), .init(rendering: .virtualSurround, offerVirtualSurround: false))
        XCTAssertEqual(decide(.auto, sony, false), .init(rendering: .spatial, offerVirtualSurround: false))
        // Explicit modes apply to every device and never ask.
        XCTAssertEqual(decide(.virtualSurround, airPods).rendering, .virtualSurround)
        XCTAssertEqual(decide(.spatial, sony, true), .init(rendering: .spatial, offerVirtualSurround: false))
        XCTAssertEqual(decide(.stereo, tv).rendering, .stereo)
    }

    /// The device-change state machine one player goes through.
    func testRouteTrackerSequence() {
        var tracker = AudioRouteTracker()
        var remembered: [String: Bool] = [:]
        var dismissed: Set<String> = []
        func step(_ device: AudioOutputDevice?, mode: AudioMode = .auto, channels: Int) -> [AudioRouteTracker.Action] {
            tracker.update(.init(mode: mode, device: device, remembered: device.flatMap { remembered[$0.uid] },
                                 sourceChannels: channels, offerDismissed: device.map { dismissed.contains($0.uid) } ?? false))
        }

        // Opening on the Sony, before the track is known: Apple's path, nothing to offer yet.
        XCTAssertEqual(step(sony, channels: 0), [.render(.spatial)])
        // A 5.1 track: offer Virtual Surround.
        XCTAssertEqual(step(sony, channels: 6), [.offer(sony)])
        XCTAssertEqual(step(sony, channels: 6), [], "no repeats")
        // Accepted (remembered for the device): switch, banner goes.
        remembered[sony.uid] = true
        XCTAssertEqual(step(sony, channels: 6), [.render(.virtualSurround), .withdrawOffer])
        // AirPods connect mid-film: back to Apple Spatial Audio.
        XCTAssertEqual(step(airPods, channels: 6), [.render(.spatial), .announce("AirPods Pro · Apple Spatial Audio")])
        // And back to the Sony: remembered, no question.
        XCTAssertEqual(step(sony, channels: 6), [.render(.virtualSurround), .announce("WH-1000XM5 · Virtual Surround")])
        // Forced Stereo from the menu.
        XCTAssertEqual(step(sony, mode: .stereo, channels: 6), [.render(.stereo)])
        // Auto again, wired headphones, stereo track: nothing to offer.
        XCTAssertEqual(step(jack, channels: 2), [.render(.spatial), .announce("External Headphones · Apple Spatial Audio")])
        // Switching to the 7.1 track: offer.
        XCTAssertEqual(step(jack, channels: 8), [.offer(jack)])
        // ✕ for this session.
        dismissed.insert(jack.uid)
        XCTAssertEqual(step(jack, channels: 8), [.withdrawOffer])
        XCTAssertEqual(step(jack, channels: 8), [])
        // Output disappears entirely, then the speakers.
        XCTAssertEqual(step(nil, channels: 8), [])
        XCTAssertEqual(step(speakers, channels: 8), [.announce("MacBook Pro Speakers · Apple Spatial Audio")])
    }

    func testDeclinedDeviceIsNotAskedAgain() {
        var tracker = AudioRouteTracker()
        XCTAssertEqual(tracker.update(.init(mode: .auto, device: sony, remembered: nil, sourceChannels: 6)),
                       [.render(.spatial), .offer(sony)])
        XCTAssertEqual(tracker.update(.init(mode: .auto, device: sony, remembered: false, sourceChannels: 6)),
                       [.withdrawOffer])
        XCTAssertEqual(tracker.offer, nil)
        XCTAssertEqual(tracker.rendering, .spatial)
    }

    // MARK: - Stereo downmix

    func testDownmixGains() {
        func g(_ s: Speaker) -> [Float] { let x = StereoDownmixer.gains(for: s); return [x.left, x.right] }
        XCTAssertEqual(g(.frontLeft), [1, 0])
        XCTAssertEqual(g(.frontRight), [0, 1])
        XCTAssertEqual(g(.center)[0], 0.7071, accuracy: 0.001)
        XCTAssertEqual(g(.center)[1], 0.7071, accuracy: 0.001)
        XCTAssertEqual(g(.surroundLeft), [0.7071, 0])
        XCTAssertEqual(g(.rearRight), [0, 0.7071])
        XCTAssertEqual(g(.lfe), [0.5, 0.5])
        XCTAssertEqual(g(.rearCenter), [0.5, 0.5])
        XCTAssertGreaterThan(g(.frontLeftOfCenter)[0], g(.frontLeftOfCenter)[1])
        XCTAssertEqual(g(.topFrontLeft)[1], 0, accuracy: 0.001)
    }

    func testDownmixProcess() {
        let layout: [Speaker] = [.frontLeft, .frontRight, .center, .lfe, .surroundLeft, .surroundRight]
        // Frame 0: centre only. Frame 1: left surround only. Frame 2: everything loud (soft-clipped).
        let input: [Float] = [0, 0, 0.5, 0, 0, 0,
                              0, 0, 0, 0, 0.5, 0,
                              1, 1, 1, 1, 1, 1]
        let out = StereoDownmixer().process(input, speakers: layout, sampleRate: 48000)
        XCTAssertEqual(out.count, 6)
        XCTAssertEqual(out[0], 0.5 * 0.7071 * SurroundMix.masterGain, accuracy: 0.001)
        XCTAssertEqual(out[0], out[1], accuracy: 0.0001)
        XCTAssertEqual(out[2], 0.5 * 0.7071 * SurroundMix.masterGain, accuracy: 0.001)
        XCTAssertEqual(out[3], 0)
        XCTAssertLessThanOrEqual(abs(out[4]), 1)
        XCTAssertGreaterThan(out[4], 0.9)
    }

    func testSoftClip() {
        XCTAssertEqual(SurroundMix.softClip(0.5), 0.5)
        XCTAssertEqual(SurroundMix.softClip(-0.9), -0.9)
        XCTAssertLessThan(SurroundMix.softClip(3), 1.0001)
        XCTAssertGreaterThan(SurroundMix.softClip(1.2), SurroundMix.softClip(1.0))
        XCTAssertEqual(SurroundMix.softClip(-2), -SurroundMix.softClip(2))
    }
}
