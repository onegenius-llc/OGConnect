import AVFoundation
import UIKit

/// Shows the remote window and translates touches, pointer input and key presses into `InputEvent`s.
///
/// Touch:    tap = click · two-finger tap = right-click · drag = move pointer ·
///           long-press then drag = click-and-drag · two-finger drag = scroll
/// Pointer:  behaves like a mouse plugged into the Mac.
final class RemoteVideoView: UIView, UIKeyInput, UIPointerInteractionDelegate {
    private final class VideoLayerView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    }

    /// Holds the picture. It stops at the top of the keyboard, so the whole remote window stays
    /// visible while typing instead of being covered.
    private let videoView = VideoLayerView()

    var displayLayer: AVSampleBufferDisplayLayer { videoView.layer as! AVSampleBufferDisplayLayer }

    var sendInput: ((InputEvent) -> Void)?
    /// Modifiers latched from the on-screen key bar; they apply to the next key or click.
    var stickyModifiers: (() -> Modifiers)?
    var consumeStickyModifiers: (() -> Void)?

    /// Pixel size of the incoming video, used to find where the picture sits inside the view.
    var videoSize: CGSize = .zero
    /// Width of the remote window in Mac points, so scrolling moves content 1:1 under the fingers.
    var remotePointWidth: CGFloat = 0

    var softKeyboardEnabled = false {
        didSet {
            if softKeyboardEnabled != oldValue { reloadInputViews() }
        }
    }

    /// Extra keys shown attached to the top of the keyboard.
    var keyBar: UIView?

    private let emptyInputView = UIView(frame: .zero)
    private var heldModifierKeys: [UIKeyboardHIDUsage: Modifiers] = [:]
    private var repeatTimer: Timer?
    private var repeatingKey: UIKeyboardHIDUsage?

    private var lastTapTime: CFTimeInterval = 0
    private var lastTapLocation = CGPoint.zero
    private var lastTapPoint = (x: 0.0, y: 0.0)
    private var tapCount = 0
    private var pointerButton: Int?
    private var isTouchDragging = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        isMultipleTouchEnabled = true

        videoView.isUserInteractionEnabled = false
        videoView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(videoView)
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: topAnchor),
            videoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: trailingAnchor),
            videoView.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
        ])
        setUpGestures()
        addInteraction(UIPointerInteraction(delegate: self))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            becomeFirstResponder()
        } else {
            releaseAllKeys()
        }
    }

    // MARK: - Coordinates

    private var videoRect: CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return .zero }
        return AVMakeRect(aspectRatio: videoSize, insideRect: videoView.frame)
    }

    private func normalized(_ location: CGPoint) -> (x: Double, y: Double)? {
        let rect = videoRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        return (Double(min(max((location.x - rect.minX) / rect.width, 0), 1)),
                Double(min(max((location.y - rect.minY) / rect.height, 0), 1)))
    }

    private var modifiers: Modifiers {
        heldModifierKeys.values.reduce(stickyModifiers?() ?? []) { $0.union($1) }
    }

    // MARK: - Touch gestures

    private func setUpGestures() {
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.allowedTouchTypes = direct

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.allowedTouchTypes = direct

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPress.minimumPressDuration = 0.35
        longPress.allowedTouchTypes = direct

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = direct
        pan.require(toFail: longPress)

        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.allowedTouchTypes = direct

        // Scroll wheel / trackpad two-finger scroll. No touch types: it only reacts to scroll events.
        let wheel = UIPanGestureRecognizer(target: self, action: #selector(handleScroll))
        wheel.allowedScrollTypesMask = .all
        wheel.allowedTouchTypes = []

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover))

        [tap, twoFingerTap, longPress, pan, twoFingerPan, wheel, hover].forEach(addGestureRecognizer)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)
        guard var point = normalized(location) else { return }

        let now = CACurrentMediaTime()
        if now - lastTapTime < 0.4, hypot(location.x - lastTapLocation.x, location.y - lastTapLocation.y) < 32 {
            // Fingers never land on the same spot twice; the Mac needs them to for a double-click.
            tapCount += 1
            point = lastTapPoint
        } else {
            tapCount = 1
        }
        lastTapTime = now
        lastTapLocation = location
        lastTapPoint = point

        click(button: 0, clicks: tapCount, at: point)
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        guard let point = normalized(gesture.location(in: self)) else { return }
        click(button: 1, clicks: 1, at: point)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed,
              let point = normalized(gesture.location(in: self)) else { return }
        sendInput?(.move(x: point.x, y: point.y, mods: modifiers))
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard let point = normalized(gesture.location(in: self)) else { return }
        switch gesture.state {
        case .began:
            isTouchDragging = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            sendInput?(.move(x: point.x, y: point.y, mods: modifiers))
            sendInput?(.button(0, down: true, clicks: 1, x: point.x, y: point.y, mods: modifiers))
        case .changed:
            sendInput?(.move(x: point.x, y: point.y, mods: modifiers))
        case .ended, .cancelled, .failed:
            guard isTouchDragging else { return }
            isTouchDragging = false
            sendInput?(.button(0, down: false, clicks: 1, x: point.x, y: point.y, mods: modifiers))
            consumeStickyModifiers?()
        default:
            break
        }
    }

    @objc private func handleScroll(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed, let point = normalized(gesture.location(in: self)) else { return }
        let translation = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)

        let width = videoRect.width
        let scale = (remotePointWidth > 0 && width > 0) ? remotePointWidth / width : 1
        sendInput?(.scroll(dx: Double(translation.x * scale), dy: Double(translation.y * scale),
                           x: point.x, y: point.y, mods: modifiers))
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard gesture.state == .began || gesture.state == .changed, pointerButton == nil,
              let point = normalized(gesture.location(in: self)) else { return }
        sendInput?(.move(x: point.x, y: point.y, mods: modifiers))
    }

    private func click(button: Int, clicks: Int, at point: (x: Double, y: Double)) {
        let mods = modifiers
        sendInput?(.move(x: point.x, y: point.y, mods: mods))
        sendInput?(.button(button, down: true, clicks: clicks, x: point.x, y: point.y, mods: mods))
        sendInput?(.button(button, down: false, clicks: clicks, x: point.x, y: point.y, mods: mods))
        consumeStickyModifiers?()
    }

    // MARK: - Mouse / trackpad buttons

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first(where: { $0.type == .indirectPointer }),
              let point = normalized(touch.location(in: self)) else {
            super.touchesBegan(touches, with: event)
            return
        }
        let button = event?.buttonMask.contains(.secondary) == true ? 1 : 0
        pointerButton = button
        sendInput?(.move(x: point.x, y: point.y, mods: modifiers))
        sendInput?(.button(button, down: true, clicks: touch.tapCount, x: point.x, y: point.y, mods: modifiers))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard pointerButton != nil,
              let touch = touches.first(where: { $0.type == .indirectPointer }),
              let point = normalized(touch.location(in: self)) else {
            super.touchesMoved(touches, with: event)
            return
        }
        sendInput?(.move(x: point.x, y: point.y, mods: modifiers))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !endPointerTouch(touches) { super.touchesEnded(touches, with: event) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !endPointerTouch(touches) { super.touchesCancelled(touches, with: event) }
    }

    private func endPointerTouch(_ touches: Set<UITouch>) -> Bool {
        guard let button = pointerButton,
              let touch = touches.first(where: { $0.type == .indirectPointer }) else { return false }
        pointerButton = nil
        if let point = normalized(touch.location(in: self)) {
            sendInput?(.button(button, down: false, clicks: touch.tapCount, x: point.x, y: point.y, mods: modifiers))
        }
        consumeStickyModifiers?()
        return true
    }

    /// The Mac's own cursor is part of the picture, so hide the iPad's to avoid showing two.
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden()
    }

    // MARK: - Hardware keyboard

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let keyCode = KeyCodes.macKeyCode(for: key.keyCode) else {
                unhandled.insert(press)
                continue
            }
            if let modifier = KeyCodes.modifier(for: key.keyCode) {
                heldModifierKeys[key.keyCode] = modifier
                sendInput?(.key(keyCode, down: true, mods: modifiers))
            } else {
                sendInput?(.key(keyCode, down: true, mods: modifiers))
                startRepeating(key.keyCode, keyCode: keyCode)
            }
        }
        // Not forwarding handled presses keeps UIKit from also turning them into insertText calls.
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = release(presses)
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let unhandled = release(presses)
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    private func release(_ presses: Set<UIPress>) -> Set<UIPress> {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let keyCode = KeyCodes.macKeyCode(for: key.keyCode) else {
                unhandled.insert(press)
                continue
            }
            if KeyCodes.modifier(for: key.keyCode) != nil {
                heldModifierKeys[key.keyCode] = nil
                sendInput?(.key(keyCode, down: false, mods: modifiers))
            } else {
                if repeatingKey == key.keyCode { stopRepeating() }
                sendInput?(.key(keyCode, down: false, mods: modifiers))
                consumeStickyModifiers?()
            }
        }
        return unhandled
    }

    /// iPadOS reports a held key once; the Mac only auto-repeats real hardware, so repeat it here.
    private func startRepeating(_ usage: UIKeyboardHIDUsage, keyCode: UInt16) {
        stopRepeating()
        repeatingKey = usage
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.sendInput?(.key(keyCode, down: true, mods: self.modifiers, isRepeat: true))
            }
        }
    }

    private func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeatingKey = nil
    }

    /// Lifts any modifier still held so it can't stay stuck down on the Mac.
    func releaseAllKeys() {
        stopRepeating()
        let held = heldModifierKeys
        heldModifierKeys = [:]
        for usage in held.keys {
            if let keyCode = KeyCodes.macKeyCode(for: usage) {
                sendInput?(.key(keyCode, down: false, mods: []))
            }
        }
    }

    // MARK: - On-screen keyboard

    /// An empty input view keeps the system keyboard away while this view stays first responder
    /// (which it must, to receive hardware key presses).
    override var inputView: UIView? { softKeyboardEnabled ? nil : emptyInputView }

    override var inputAccessoryView: UIView? { softKeyboardEnabled ? keyBar : nil }

    var hasText: Bool { true }

    func insertText(_ text: String) {
        sendInput?(.text(text, mods: modifiers))
        consumeStickyModifiers?()
    }

    func deleteBackward() {
        sendInput?(.key(KeyCodes.delete, down: true, mods: modifiers))
        sendInput?(.key(KeyCodes.delete, down: false, mods: modifiers))
        consumeStickyModifiers?()
    }

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
}
