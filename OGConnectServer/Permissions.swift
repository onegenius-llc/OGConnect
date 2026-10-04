import AppKit
import ApplicationServices

enum Permissions {
    /// Needed to list and capture windows.
    static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Needed to post mouse/keyboard events and raise windows.
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// macOS only shows its own prompt the first time an app asks. `openSettings` covers every
    /// time after that, when the user has to flip the switch in System Settings themselves.
    static func requestScreenRecording(openSettings: Bool) {
        if !CGRequestScreenCaptureAccess(), openSettings {
            self.openSettings("Privacy_ScreenCapture")
        }
    }

    static func requestAccessibility(openSettings: Bool) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options), openSettings {
            self.openSettings("Privacy_Accessibility")
        }
    }

    private static func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
