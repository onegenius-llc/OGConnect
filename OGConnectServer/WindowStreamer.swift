import AppKit
import ApplicationServices
import ScreenCaptureKit

struct StreamError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Captures one window and feeds it to the encoder.
///
/// The capture is the window's rectangle cut out of its display, showing only the owning app's
/// windows. Capturing the bare window instead would hide the app's menus, popovers and sheets,
/// which are separate windows, and make it impossible to drive remotely.
final class WindowStreamer: NSObject, SCStreamOutput, SCStreamDelegate, InputTarget, @unchecked Sendable {
    private struct Geometry: Equatable {
        var displayID: CGDirectDisplayID
        /// Captured area in global screen coordinates (points, top-left origin).
        var captureRect: CGRect
        /// The same area relative to its display.
        var sourceRect: CGRect
        var pixelWidth: Int
        var pixelHeight: Int
    }

    let info: WindowInfo
    var onPacket: ((Data) -> Void)?
    var onEnded: ((String) -> Void)?
    var isCongested: (() -> Bool)?

    /// The app that owns the streamed window.
    let pid: pid_t
    private let windowID: CGWindowID
    private let app: SCRunningApplication?
    /// Set when streaming a menu bar item: a fixed patch of the screen with everything in it,
    /// since whatever the item opens may belong to another app.
    private let menuBarRegion: CGRect?
    private let menuBarItemCenter: CGPoint
    private let displays: [SCDisplay]
    private let queue = DispatchQueue(label: "com.onegenius.ogconnect.capture", qos: .userInteractive)
    private let encoder = H264Encoder()

    // Everything below is confined to `queue`, except `_captureRect` which is guarded by `lock`.
    private var stream: SCStream?
    private var timer: DispatchSourceTimer?
    private var running = false
    private var applied: Geometry
    private var updating = false
    private var lastBuffer: CVPixelBuffer?
    private var lastFrameTime: CFTimeInterval = 0
    private var refinesLeft = 0
    private var resendNeeded = false
    private var keyframeNeeded = true

    private let lock = NSLock()
    private var _captureRect: CGRect

    var captureRect: CGRect { lock.withLock { _captureRect } }

    init(window: SCWindow, info: WindowInfo, content: SCShareableContent) throws {
        guard let app = window.owningApplication else {
            throw StreamError("That window can't be shared.")
        }
        let bounds = Self.windowBounds(window.windowID) ?? window.frame
        let region = window.windowLayer != 0 ? MenuBarRegion.rect(around: bounds) : nil
        guard let geometry = Self.geometry(for: region ?? bounds) else {
            throw StreamError("That window isn't visible on any display.")
        }
        self.info = info
        self.windowID = window.windowID
        self.pid = app.processID
        self.app = app
        self.menuBarRegion = region
        self.menuBarItemCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        self.displays = content.displays
        self.applied = geometry
        self._captureRect = geometry.captureRect
        super.init()
        encoder.onPacket = { [weak self] in self?.onPacket?($0) }
    }

    func start() async throws {
        guard let display = display(applied.displayID) else {
            throw StreamError("That window isn't visible on any display.")
        }
        if menuBarRegion == nil { bringToFront() }

        let stream = SCStream(filter: filter(display), configuration: Self.configuration(applied), delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        queue.sync {
            self.stream = stream
            self.running = true
        }
        do {
            try await stream.startCapture()
        } catch {
            queue.sync { self.running = false }
            throw error
        }
        queue.async { self.startTimer() }

        if menuBarRegion != nil {
            // Open the item the way a click on it would, once the stream is up to show the result.
            try? await Task.sleep(for: .milliseconds(300))
            Self.click(at: menuBarItemCenter)
        }
    }

    private static func click(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            usleep(30_000)
        }
    }

    func stop() {
        queue.async { self.tearDown() }
    }

    func requestKeyframe() {
        queue.async {
            self.keyframeNeeded = true
            self.resendNeeded = true
        }
    }

    // MARK: - Capture

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard running, type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        lastBuffer = pixelBuffer
        lastFrameTime = CACurrentMediaTime()
        refinesLeft = 2
        encodeLatest()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.finish(error.localizedDescription) }
    }

    /// Encodes the most recent frame, unless the client is behind — in which case it's skipped
    /// before the encoder sees it and picked up again by the timer.
    private func encodeLatest() {
        guard let lastBuffer else { return }
        if isCongested?() == true {
            resendNeeded = true
            return
        }
        resendNeeded = false
        encoder.encode(lastBuffer, forceKeyframe: keyframeNeeded)
        keyframeNeeded = false
    }

    private func startTimer() {
        guard running else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard running else { return }

        guard let bounds = menuBarRegion ?? Self.windowBounds(windowID) else {
            finish("The window was closed.")
            return
        }
        if !updating, let geometry = Self.geometry(for: bounds), geometry != applied {
            apply(geometry)
        }

        // ScreenCaptureKit only delivers frames when something changes, so a rate-limited frame
        // would otherwise stay soft forever. Re-encoding it once things go quiet sharpens it up.
        if resendNeeded {
            encodeLatest()
        } else if refinesLeft > 0, CACurrentMediaTime() - lastFrameTime > 0.25 {
            refinesLeft -= 1
            encodeLatest()
        }
    }

    private func apply(_ geometry: Geometry) {
        guard let stream else { return }
        updating = true
        lock.withLock { _captureRect = geometry.captureRect }
        let newDisplay = geometry.displayID != applied.displayID ? display(geometry.displayID) : nil
        Task {
            if let newDisplay {
                try? await stream.updateContentFilter(self.filter(newDisplay))
            }
            try? await stream.updateConfiguration(Self.configuration(geometry))
            self.queue.async {
                self.applied = geometry
                self.updating = false
            }
        }
    }

    private func finish(_ reason: String) {
        guard running else { return }
        tearDown()
        onEnded?(reason)
    }

    private func tearDown() {
        guard running else { return }
        running = false
        timer?.cancel()
        timer = nil
        lastBuffer = nil
        encoder.invalidate()
        stream?.stopCapture { _ in }
        stream = nil
    }

    private func display(_ id: CGDirectDisplayID) -> SCDisplay? {
        displays.first { $0.displayID == id }
    }

    private func filter(_ display: SCDisplay) -> SCContentFilter {
        guard menuBarRegion == nil, let app else {
            return SCContentFilter(display: display, excludingWindows: [])
        }
        return SCContentFilter(display: display, including: [app], exceptingWindows: [])
    }

    private static func configuration(_ geometry: Geometry) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = geometry.sourceRect
        configuration.width = geometry.pixelWidth
        configuration.height = geometry.pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorSpaceName = CGColorSpace.sRGB
        return configuration
    }

    // MARK: - Geometry

    private static func windowBounds(_ windowID: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let boundsValue = list.first?[kCGWindowBounds as String] else { return nil }
        return CGRect(dictionaryRepresentation: boundsValue as! CFDictionary)
    }

    private static func geometry(for bounds: CGRect) -> Geometry? {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)

        var best: (id: CGDirectDisplayID, rect: CGRect, frame: CGRect)?
        for id in ids.prefix(Int(count)) {
            let frame = CGDisplayBounds(id)
            let visible = bounds.intersection(frame)
            guard !visible.isNull else { continue }
            if best == nil || visible.width * visible.height > best!.rect.width * best!.rect.height {
                best = (id, visible, frame)
            }
        }
        guard let best, best.rect.width >= 16, best.rect.height >= 16 else { return nil }

        var scale: CGFloat = 2
        if let mode = CGDisplayCopyDisplayMode(best.id), mode.width > 0 {
            scale = CGFloat(mode.pixelWidth) / CGFloat(mode.width)
        }
        var width = best.rect.width * scale
        var height = best.rect.height * scale
        // Stay within what the hardware H.264 encoder accepts.
        let limit = min(1, 4096 / max(width, height), (8_294_400 / (width * height)).squareRoot())
        width *= limit
        height *= limit

        return Geometry(displayID: best.id,
                        captureRect: best.rect,
                        sourceRect: best.rect.offsetBy(dx: -best.frame.minX, dy: -best.frame.minY),
                        pixelWidth: max(2, Int(width.rounded()) & ~1),
                        pixelHeight: max(2, Int(height.rounded()) & ~1))
    }

    // MARK: - InputTarget

    func bringToFrontIfNeeded() {
        // Activating anything would dismiss the menu an item has just opened.
        guard menuBarRegion == nil else { return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else { return }
        bringToFront()
        // Give the window server a moment so the event that follows lands on this window.
        usleep(120_000)
    }

    private func bringToFront() {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 1)

        if let bounds = Self.windowBounds(windowID) {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
               let windows = value as? [AXUIElement] {
                let candidates = windows.filter { Self.frame(of: $0).map { Self.isClose($0, bounds) } ?? false }
                let match = candidates.first { Self.title(of: $0) == info.title } ?? candidates.first
                if let match {
                    AXUIElementPerformAction(match, kAXRaiseAction as CFString)
                    AXUIElementSetAttributeValue(match, kAXMainAttribute as CFString, kCFBooleanTrue)
                }
            }
        }
        AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    private static func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    private static func title(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }
}
