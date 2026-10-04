import AppKit

/// The apps installed on this Mac, so a client can launch one that isn't running yet.
enum AppCatalog {
    struct Entry {
        var url: URL
        var name: String
    }

    static func scan() -> [Entry] {
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]

        var urls: [URL] = [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]
        for root in roots {
            for item in contents(of: root) {
                if item.pathExtension == "app" {
                    urls.append(item)
                } else {
                    // One level of folders, e.g. Utilities or a vendor's suite folder.
                    urls.append(contentsOf: contents(of: item).filter { $0.pathExtension == "app" })
                }
            }
        }

        var seen = Set<String>()
        return urls
            .filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
            .map { url in
                var name = fileManager.displayName(atPath: url.path)
                if name.hasSuffix(".app") { name.removeLast(4) }
                return Entry(url: url, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func runningAppURLs() -> Set<URL> {
        Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.resolvingSymlinksInPath() })
    }

    /// The app's icon as PNG data. Uses AppKit drawing, so call it on the main thread.
    static func icon(for url: URL, size: Int = 128) -> Data? {
        let image = NSWorkspace.shared.icon(forFile: url.path)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    /// Launches the app, or brings it forward and reopens a window if it's already running.
    static func launch(_ url: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private static func contents(of directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles])) ?? []
    }
}
