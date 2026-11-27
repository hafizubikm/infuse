import Foundation
import IOKit.pwr_mgt

/// Keeps the display awake while video plays (IOPMAssertion PreventUserIdleDisplaySleep).
final class DisplaySleepAssertion {
    private var assertionID: IOPMAssertionID = 0
    private var held = false

    func acquire() {
        guard !held else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Reel is playing video" as CFString,
            &assertionID)
        held = result == kIOReturnSuccess
    }

    func release() {
        guard held else { return }
        IOPMAssertionRelease(assertionID)
        held = false
    }

    deinit { release() }
}
