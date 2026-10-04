import ApplicationServices
import Foundation

/// Reads an app's menu bar through the Accessibility API and presses items in it.
/// The menus don't have to be open or even on screen. Calls can block on a busy app; use off the main thread.
enum MenuReader {
    /// The items one level down `path`: an empty path is the menu bar itself, `[1]` the contents
    /// of its second menu, `[1, 4]` the submenu of that menu's fifth item, and so on.
    static func items(pid: pid_t, path: [Int]) -> [MenuItemInfo]? {
        guard let elements = elements(pid: pid, path: path) else { return nil }
        return elements.enumerated().map { index, element in
            info(for: element, index: index, inMenuBar: path.isEmpty)
        }
    }

    /// Presses the item at `path`. The title guards against the menu having changed since it was listed.
    static func press(pid: pid_t, path: [Int], title: String) -> Bool {
        guard let index = path.last,
              let elements = elements(pid: pid, path: Array(path.dropLast())),
              elements.indices.contains(index) else { return false }
        let element = elements[index]
        guard (value(of: element, kAXTitleAttribute) as? String ?? "") == title else { return false }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private static func elements(pid: pid_t, path: [Int]) -> [AXUIElement]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 2)
        guard let barValue = value(of: app, kAXMenuBarAttribute),
              CFGetTypeID(barValue) == AXUIElementGetTypeID() else { return nil }

        var level = children(of: barValue as! AXUIElement)
        for index in path {
            guard level.indices.contains(index) else { return nil }
            // An item with a submenu has a single AXMenu child, which holds the actual items.
            guard let menu = children(of: level[index]).first else { return [] }
            level = children(of: menu)
        }
        return level
    }

    private static func info(for element: AXUIElement, index: Int, inMenuBar: Bool) -> MenuItemInfo {
        let attributes = [kAXTitleAttribute, kAXEnabledAttribute, kAXMenuItemMarkCharAttribute,
                          kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXChildrenAttribute]
        var result: CFArray?
        AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &result)
        let values = (result as? [Any]) ?? []
        func value(_ position: Int) -> Any? { values.indices.contains(position) ? values[position] : nil }

        let title = value(0) as? String ?? ""
        let mark = value(2) as? String ?? ""
        let hasSubmenu = !((value(5) as? [AXUIElement]) ?? []).isEmpty
        var shortcut: String?
        // Shortcuts on keys like Escape come through as control characters, which can't be shown.
        if let character = value(3) as? String, let scalar = character.unicodeScalars.first, scalar.value > 0x20, scalar.value != 0x7F {
            shortcut = shortcutText(character: character, modifiers: value(4) as? Int ?? 0)
        }

        return MenuItemInfo(index: index,
                            title: title,
                            enabled: value(1) as? Bool ?? true,
                            checked: !mark.isEmpty,
                            shortcut: shortcut,
                            hasSubmenu: inMenuBar || hasSubmenu,
                            isSeparator: title.isEmpty && !inMenuBar)
    }

    /// `modifiers` is the Accessibility encoding: Command is implied unless bit 3 is set.
    private static func shortcutText(character: String, modifiers: Int) -> String {
        var text = ""
        if modifiers & 4 != 0 { text += "⌃" }
        if modifiers & 2 != 0 { text += "⌥" }
        if modifiers & 1 != 0 { text += "⇧" }
        if modifiers & 8 == 0 { text += "⌘" }
        return text + character.uppercased()
    }

    private static func value(of element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        (value(of: element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}
