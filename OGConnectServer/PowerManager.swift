import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Keeps the display — and with it the Mac — from idling to sleep.
///
/// macOS locks the screen when the display sleeps or the screen saver starts, and a locked
/// screen hides every window from capture. Holding the display awake is what prevents that.
final class PowerManager {
    enum Mode: String, CaseIterable, Identifiable {
        case never
        case whileConnected
        case always

        var id: String { rawValue }

        var title: String {
            switch self {
            case .never: return "Never"
            case .whileConnected: return "While a device is connected"
            case .always: return "Whenever the server is running"
            }
        }
    }

    private var assertion = IOPMAssertionID(kIOPMNullAssertionID)
    private static var activityAssertion = IOPMAssertionID(kIOPMNullAssertionID)

    var isHoldingAwake: Bool { assertion != IOPMAssertionID(kIOPMNullAssertionID) }

    func setHoldingAwake(_ hold: Bool) {
        guard hold != isHoldingAwake else { return }
        if hold {
            var id = IOPMAssertionID(kIOPMNullAssertionID)
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "OGConnect Server is sharing a window" as CFString,
                                                     &id)
            if result == kIOReturnSuccess { assertion = id }
        } else {
            IOPMAssertionRelease(assertion)
            assertion = IOPMAssertionID(kIOPMNullAssertionID)
        }
    }

    /// Turns the display back on if it has gone to sleep, as touching the keyboard would.
    static func wakeDisplay() {
        IOPMAssertionDeclareUserActivity("OGConnect device connected" as CFString, kIOPMUserActiveLocal, &activityAssertion)
    }

    static var isScreenLocked: Bool {
        #if DEBUG
        // Lets the locked-Mac UI be exercised without actually locking the Mac.
        if ProcessInfo.processInfo.environment["OGCONNECT_TEST_LOCKED"] != nil { return true }
        #endif
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    static let lockedMessage = "The Mac is locked, so its windows can't be shared. Unlock it first."
}
