import CoreGraphics
import Foundation

protocol InputTarget: AnyObject {
    /// The streamed area in global screen coordinates.
    var captureRect: CGRect { get }
    func bringToFrontIfNeeded()
}

/// Turns client input events into system mouse and keyboard events. Use from a single queue.
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonsDown: Set<Int> = []
    private var lastPoint: CGPoint?
    private var lastButtonDown: CFAbsoluteTime = 0

    func handle(_ event: InputEvent, target: InputTarget) {
        switch event.kind {
        case .move:
            guard let point = point(event, in: target.captureRect) else { return }
            move(to: point, mods: event.mods)

        case .button:
            guard let point = point(event, in: target.captureRect) else { return }
            let button = event.button ?? 0
            let down = event.down ?? false
            if down {
                target.bringToFrontIfNeeded()
                buttonsDown.insert(button)
                lastButtonDown = CFAbsoluteTimeGetCurrent()
            } else {
                buttonsDown.remove(button)
                // A tap arrives as down+up back to back; apps that poll the mouse miss a click
                // with no duration, so hold the button for a moment like a real one.
                let held = CFAbsoluteTimeGetCurrent() - lastButtonDown
                if held < 0.03 { usleep(useconds_t((0.03 - held) * 1_000_000)) }
            }
            let type: CGEventType
            switch (button, down) {
            case (0, true): type = .leftMouseDown
            case (0, false): type = .leftMouseUp
            case (1, true): type = .rightMouseDown
            case (1, false): type = .rightMouseUp
            case (_, true): type = .otherMouseDown
            case (_, false): type = .otherMouseUp
            }
            postMouse(type, at: point, button: button, clicks: event.clicks ?? 1, mods: event.mods)

        case .scroll:
            guard let point = point(event, in: target.captureRect) else { return }
            // Scroll events go to whatever is under the cursor, so put it over the window first.
            if lastPoint != point { move(to: point, mods: event.mods) }
            guard let scroll = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                       wheel1: Int32((event.dy ?? 0).rounded()),
                                       wheel2: Int32((event.dx ?? 0).rounded()),
                                       wheel3: 0) else { return }
            apply(event.mods, to: scroll)
            scroll.post(tap: .cghidEventTap)

        case .key:
            guard let keyCode = event.keyCode, let down = event.down else { return }
            if down { target.bringToFrontIfNeeded() }
            postKey(keyCode, down: down, mods: event.mods, isRepeat: event.isRepeat ?? false)

        case .text:
            guard let text = event.text, !text.isEmpty else { return }
            target.bringToFrontIfNeeded()
            type(text, mods: event.mods)
        }
    }

    // MARK: - Mouse

    private func point(_ event: InputEvent, in rect: CGRect) -> CGPoint? {
        guard let x = event.x, let y = event.y, rect.width > 1, rect.height > 1 else { return nil }
        return CGPoint(x: rect.minX + CGFloat(min(max(x, 0), 1)) * (rect.width - 1),
                       y: rect.minY + CGFloat(min(max(y, 0), 1)) * (rect.height - 1))
    }

    private func move(to point: CGPoint, mods: Modifiers) {
        let type: CGEventType
        let button: Int
        if buttonsDown.contains(0) {
            (type, button) = (.leftMouseDragged, 0)
        } else if buttonsDown.contains(1) {
            (type, button) = (.rightMouseDragged, 1)
        } else if let other = buttonsDown.first {
            (type, button) = (.otherMouseDragged, other)
        } else {
            (type, button) = (.mouseMoved, 0)
        }
        postMouse(type, at: point, button: button, clicks: buttonsDown.isEmpty ? 0 : 1, mods: mods)
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, button: Int, clicks: Int, mods: Modifiers) {
        let cgButton = CGMouseButton(rawValue: UInt32(button)) ?? .left
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        if let lastPoint {
            event.setIntegerValueField(.mouseEventDeltaX, value: Int64(point.x - lastPoint.x))
            event.setIntegerValueField(.mouseEventDeltaY, value: Int64(point.y - lastPoint.y))
        }
        apply(mods, to: event)
        event.post(tap: .cghidEventTap)
        lastPoint = point
    }

    // MARK: - Keyboard

    private func postKey(_ keyCode: UInt16, down: Bool, mods: Modifiers, isRepeat: Bool = false) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        if KeyMap.modifierKeyCodes.contains(keyCode) {
            event.type = .flagsChanged
        }
        if isRepeat {
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        apply(mods, to: event)
        event.post(tap: .cghidEventTap)
    }

    private func tap(_ keyCode: UInt16, mods: Modifiers) {
        postKey(keyCode, down: true, mods: mods)
        postKey(keyCode, down: false, mods: mods)
    }

    private func type(_ text: String, mods: Modifiers) {
        let isShortcut = !mods.isDisjoint(with: [.command, .control, .option])
        for character in text {
            if character == "\n" {
                tap(0x24, mods: mods)
            } else if character == "\t" {
                tap(0x30, mods: mods)
            } else if isShortcut, let key = KeyMap.usKey(for: character) {
                // Shortcuts are matched on key codes, so a bare Unicode event wouldn't trigger them.
                tap(key.keyCode, mods: key.shift ? mods.union(.shift) : mods)
            } else {
                let string = mods.contains(.shift) ? String(character).uppercased() : String(character)
                postUnicode(string)
            }
        }
    }

    private func postUnicode(_ string: String) {
        let units = Array(string.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            apply([], to: event)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Replaces the event's modifier state with the client's, leaving other flags (fn, numeric pad) intact.
    private func apply(_ mods: Modifiers, to event: CGEvent) {
        var flags = event.flags
        flags.subtract([.maskShift, .maskControl, .maskAlternate, .maskCommand])
        if mods.contains(.shift) { flags.insert(.maskShift) }
        if mods.contains(.control) { flags.insert(.maskControl) }
        if mods.contains(.option) { flags.insert(.maskAlternate) }
        if mods.contains(.command) { flags.insert(.maskCommand) }
        event.flags = flags
    }
}

enum KeyMap {
    static let modifierKeyCodes: Set<UInt16> = [0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E]

    /// Key code (US layout) that produces a character, and whether Shift is needed.
    static func usKey(for character: Character) -> (keyCode: UInt16, shift: Bool)? {
        if let code = unshifted[character] { return (code, false) }
        if let code = shifted[character] { return (code, true) }
        return nil
    }

    private static let unshifted: [Character: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
        "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
        "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, " ": 0x31, "`": 0x32,
    ]

    private static let shifted: [Character: UInt16] = [
        "A": 0x00, "S": 0x01, "D": 0x02, "F": 0x03, "H": 0x04, "G": 0x05, "Z": 0x06, "X": 0x07,
        "C": 0x08, "V": 0x09, "B": 0x0B, "Q": 0x0C, "W": 0x0D, "E": 0x0E, "R": 0x0F, "Y": 0x10,
        "T": 0x11, "!": 0x12, "@": 0x13, "#": 0x14, "$": 0x15, "^": 0x16, "%": 0x17, "+": 0x18,
        "(": 0x19, "&": 0x1A, "_": 0x1B, "*": 0x1C, ")": 0x1D, "}": 0x1E, "O": 0x1F, "U": 0x20,
        "{": 0x21, "I": 0x22, "P": 0x23, "L": 0x25, "J": 0x26, "\"": 0x27, "K": 0x28, ":": 0x29,
        "|": 0x2A, "<": 0x2B, "?": 0x2C, "N": 0x2D, "M": 0x2E, ">": 0x2F, "~": 0x32,
    ]
}
