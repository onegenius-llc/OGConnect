import AppKit
import ScreenCaptureKit

enum WindowCatalog {
    static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    }

    /// Everything a client can open: app windows first, then the menu bar's items.
    static func windows(in content: SCShareableContent) -> [WindowInfo] {
        appWindows(in: content) + menuBarItems(in: content)
    }

    /// Items in the main display's menu bar, left to right. Each is a small window of its own.
    private static func menuBarItems(in content: SCShareableContent) -> [WindowInfo] {
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let items = content.windows.filter { window in
            window.windowLayer == statusLevel && window.isOnScreen
                && window.frame.height <= 44 && window.frame.width >= 12
        }
        /// One display's menu bar items, right to left.
        func row(on display: CGRect) -> [SCWindow] {
            items.filter { display.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
                .sorted { $0.frame.maxX > $1.frame.maxX }
        }

        let mainID = CGMainDisplayID()
        let mainBounds = CGDisplayBounds(mainID)
        let mainRow = row(on: mainBounds)

        // macOS titles an item usefully on only one display at a time: third-party items carry
        // their bundle identifier on the active display, system items their name on the others.
        // Pairing each main-display item with its twin elsewhere recovers a name for both kinds.
        var twinTitles: [CGWindowID: [String]] = [:]
        for display in content.displays where display.displayID != mainID {
            let bounds = CGDisplayBounds(display.displayID)
            let otherRow = row(on: bounds)
            // Items are packed against the right edge, so twins sit at the same distance from it,
            // shifted by the width of any item that only the main display has.
            var shift: CGFloat = 0
            for item in mainRow {
                let expected = mainBounds.maxX - item.frame.maxX - shift
                if let twin = otherRow.first(where: {
                    abs((bounds.maxX - $0.frame.maxX) - expected) <= 2 && abs($0.frame.width - item.frame.width) <= 1
                }) {
                    twinTitles[item.windowID, default: []].append(twin.title ?? "")
                } else {
                    shift += item.frame.width
                }
            }
        }

        return mainRow.reversed().compactMap { window in
            let titles = [window.title ?? ""] + (twinTitles[window.windowID] ?? [])
            guard let name = menuBarItemName(window, titles: titles) else { return nil }
            return WindowInfo(id: window.windowID, title: name, appName: "Menu Bar",
                              width: Int(MenuBarRegion.size.width), height: Int(MenuBarRegion.size.height),
                              isMenuBarItem: true)
        }
    }

    /// Recent versions of macOS host every item in Control Center and put the real owner's
    /// bundle identifier in the window title; older ones leave the item with its own app.
    private static func menuBarItemName(_ window: SCWindow, titles: [String]) -> String? {
        let ownBundleID = Bundle.main.bundleIdentifier
        guard let owner = window.owningApplication, owner.bundleIdentifier != ownBundleID else { return nil }
        guard owner.bundleIdentifier == "com.apple.controlcenter" else { return owner.applicationName }

        if let ownBundleID, titles.contains(ownBundleID) { return nil }
        guard let title = titles.first(where: { !$0.isEmpty && !$0.hasPrefix("Item-") }) else { return "Menu Bar Item" }
        if title.hasPrefix("BentoBox") { return "Control Center" }
        if title == "WiFi" { return "Wi-Fi" }
        if title == "NowPlaying" { return "Now Playing" }
        if title == "FocusModes" { return "Focus" }
        guard title.contains(".") else { return title }

        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: title).first,
           let name = app.localizedName, !name.isEmpty {
            return name
        }
        let parts = title.split(separator: ".").map(String.init)
        return parts.last { $0.lowercased() != "menu" } ?? title
    }

    /// Normal app windows currently on screen, front-most first.
    private static func appWindows(in content: SCShareableContent) -> [WindowInfo] {
        content.windows.compactMap { window in
            guard window.windowLayer == 0,
                  window.isOnScreen,
                  window.frame.width >= 120, window.frame.height >= 80,
                  let app = window.owningApplication,
                  !app.applicationName.isEmpty,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
            let title = window.title ?? ""
            return WindowInfo(id: window.windowID,
                              title: title.isEmpty ? app.applicationName : title,
                              appName: app.applicationName,
                              width: Int(window.frame.width),
                              height: Int(window.frame.height))
        }
    }

    /// A menu bar item's window is an empty placeholder for content drawn elsewhere, so its
    /// picture is taken from the screen itself: whatever the menu bar shows at that spot.
    private static func menuBarItemImage(of window: SCWindow, in content: SCShareableContent) async -> Data? {
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        guard let display = content.displays.first(where: { CGDisplayBounds($0.displayID).contains(center) }) else { return nil }
        let screen = CGDisplayBounds(display.displayID)

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = window.frame.offsetBy(dx: -screen.minX, dy: -screen.minY)
        configuration.width = max(2, Int(window.frame.width * 2))
        configuration.height = max(2, Int(window.frame.height * 2))
        configuration.showsCursor = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func thumbnail(of window: SCWindow, in content: SCShareableContent, maxDimension: Int) async -> Data? {
        if window.windowLayer != 0 {
            return await menuBarItemImage(of: window, in: content)
        }

        let longest = max(window.frame.width, window.frame.height)
        guard longest > 0 else { return nil }
        let scale = min(1, CGFloat(maxDimension) / longest)

        let configuration = SCStreamConfiguration()
        configuration.width = max(2, Int(window.frame.width * scale))
        configuration.height = max(2, Int(window.frame.height * scale))
        configuration.showsCursor = false

        let filter = SCContentFilter(desktopIndependentWindow: window)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}

/// The patch of screen streamed for a menu bar item: wide and tall enough for the menu or
/// popover that drops down from it.
enum MenuBarRegion {
    static let size = CGSize(width: 880, height: 660)

    static func rect(around item: CGRect) -> CGRect? {
        var count: UInt32 = 0
        var display: CGDirectDisplayID = 0
        guard CGGetDisplaysWithPoint(CGPoint(x: item.midX, y: item.midY), 1, &display, &count) == .success, count > 0 else {
            return nil
        }
        let screen = CGDisplayBounds(display)
        let width = min(size.width, screen.width)
        let height = min(size.height, screen.height)
        let x = min(max(item.midX - width / 2, screen.minX), screen.maxX - width)
        return CGRect(x: x, y: screen.minY, width: width, height: height)
    }
}
