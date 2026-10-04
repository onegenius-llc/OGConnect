import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Unlocks the Mac by typing the account password into the lock screen, the way someone sitting
/// at the keyboard would. The password is used once and never stored or logged.
enum ScreenUnlocker {
    struct Keystroke {
        var keyCode: UInt16
        var flags: CGEventFlags
        /// Set when the character isn't on the current keyboard layout and has to be sent as text.
        var text: String?
    }

    /// Resolves the password into key presses for the Mac's current keyboard layout.
    /// Must run on the main thread: the input-source APIs require it.
    static func keystrokes(for password: String) -> [Keystroke] {
        let layout = layoutMap()
        return password.map { character in
            if let key = layout[String(character)] {
                return Keystroke(keyCode: key.keyCode, flags: key.flags)
            }
            return Keystroke(keyCode: 0, flags: [], text: String(character))
        }
    }

    /// Types the password and Return, then waits to see whether the Mac unlocked.
    /// Blocks for several seconds; call it off the main thread.
    static func perform(_ keystrokes: [Keystroke]) -> Bool {
        // The lock screen only takes input once the display is on and its password field is up.
        PowerManager.wakeDisplay()
        usleep(1_000_000)

        let source = CGEventSource(stateID: .hidSystemState)
        // Clear anything left in the field by an earlier attempt.
        tap(Keystroke(keyCode: UInt16(kVK_ANSI_A), flags: .maskCommand), source: source)
        tap(Keystroke(keyCode: UInt16(kVK_Delete), flags: []), source: source)
        for keystroke in keystrokes {
            tap(keystroke, source: source)
        }
        tap(Keystroke(keyCode: UInt16(kVK_Return), flags: []), source: source)

        for _ in 0..<40 {
            if !PowerManager.isScreenLocked { return true }
            usleep(150_000)
        }
        return false
    }

    private static func tap(_ keystroke: Keystroke, source: CGEventSource?) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keystroke.keyCode, keyDown: down) else { continue }
            if let text = keystroke.text {
                let units = Array(text.utf16)
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            }
            event.flags = keystroke.flags
            event.post(tap: .cghidEventTap)
            usleep(8_000)
        }
    }

    /// Every character the current layout can produce, with the key and modifiers that produce it.
    private static func layoutMap() -> [String: (keyCode: UInt16, flags: CGEventFlags)] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data

        let combinations: [(carbon: UInt32, flags: CGEventFlags)] = [
            (0, []),
            (UInt32(shiftKey >> 8), .maskShift),
            (UInt32(optionKey >> 8), .maskAlternate),
            (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate]),
        ]

        var map: [String: (keyCode: UInt16, flags: CGEventFlags)] = [:]
        data.withUnsafeBytes { bytes in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for combination in combinations {
                for keyCode in UInt16(0)..<128 {
                    var deadKeyState: UInt32 = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    var length = 0
                    let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), combination.carbon,
                                                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                                &deadKeyState, characters.count, &length, &characters)
                    guard status == noErr, length > 0 else { continue }
                    let string = String(utf16CodeUnits: characters, count: length)
                    // First match wins, which prefers the plainest way to type each character.
                    if map[string] == nil {
                        map[string] = (keyCode, combination.flags)
                    }
                }
            }
        }
        return map
    }
}
