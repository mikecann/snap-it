import AppKit
import Carbon.HIToolbox
import QuartzCore
import SnapItCore

/// Shows clicks and keys over the recorded area while recording, and logs them for the summary.
/// It draws into a click-through window over the area, so the recording picks it up like anything else on
/// screen, and you see what's being shown as you go.
///
/// Clicks come from NSEvent's global monitor, which needs no permission. Keys need a listen-only event tap,
/// which needs Input Monitoring. Password fields turn on secure input, which keeps their keys from the tap.
@MainActor
final class InputVisualizer {
    private(set) var timeline = InputTimeline()
    let clicksRecorded: Bool
    private(set) var keysRecorded = false
    /// The recorded area in AppKit global coordinates.
    private let region: CGRect
    private let window: NSWindow
    private let view: InputOverlayView
    private var monitors: [Any] = []
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var hudTimer: Timer?
    private var shownLabels: [String] = []

    init(region: CGRect, showClicks: Bool, showKeys: Bool) {
        self.region = region
        clicksRecorded = showClicks
        window = NSWindow(contentRect: region, styleMask: [.borderless], backing: .buffered, defer: false)
        view = InputOverlayView(frame: CGRect(origin: .zero, size: region.size))
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentView = view
        if showKeys { keysRecorded = startKeyTap() }
    }

    func start() {
        window.orderFrontRegardless()
        if clicksRecorded {
            let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                               .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
                MainActor.assumeIsolated { self?.handleMouse(event) }
            }) { monitors.append(global) }
            // Clicks on our own windows don't reach the global monitor.
            if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
                self?.handleMouse(event)
                return event
            }) { monitors.append(local) }
        }
        if keysRecorded {
            hudTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshKeys() }
            }
        }
    }

    /// Stops listening and drawing, and returns everything that happened, in host-clock times.
    func stop() -> InputTimeline {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
        hudTimer?.invalidate()
        hudTimer = nil
        window.orderOut(nil)
        timeline.finish()
        return timeline
    }

    var windowNumber: Int { window.windowNumber }

    // MARK: Mouse

    private func localPoint(_ global: CGPoint) -> CGPoint {
        CGPoint(x: global.x - region.minX, y: region.maxY - global.y)
    }

    private func handleMouse(_ event: NSEvent) {
        let now = CACurrentMediaTime()
        let point = localPoint(NSEvent.mouseLocation)
        let inside = CGRect(origin: .zero, size: region.size).contains(point)
        let button: MouseButton = switch event.type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged: .left
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged: .right
        default: .other
        }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard inside else { return }
            timeline.mouseDown(button, at: point, time: now, clickCount: event.clickCount)
            view.pressed(at: point, button: button)
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            view.dragged(to: point)
        default:
            timeline.mouseUp(button, at: point, time: now)
            view.released()
        }
    }

    // MARK: Keys

    private func startKeyTap() -> Bool {
        guard CGPreflightListenEventAccess() else {
            // Shows the system prompt the first time. It applies from the next recording.
            CGRequestListenEventAccess()
            Log.info("Keys won't show in this recording: Snap It needs Input Monitoring permission")
            return false
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                          eventsOfInterest: mask, callback: { _, type, event, refcon in
            if let refcon {
                let visualizer = Unmanaged<InputVisualizer>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { visualizer.handleTap(type: type, event: event) }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: refcon) else {
            Log.info("Keys won't show in this recording: couldn't create the key event tap")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = tap
        tapSource = source
        return true
    }

    private func handleTap(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .keyDown else { return }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        var modifiers: KeyModifiers = []
        if event.flags.contains(.maskCommand) { modifiers.insert(.command) }
        if event.flags.contains(.maskShift) { modifiers.insert(.shift) }
        if event.flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if event.flags.contains(.maskControl) { modifiers.insert(.control) }
        guard !KeyNames.isSnapItHotkey(keyCode: keyCode, modifiers: modifiers) else { return }
        // What it typed comes from the layout and the event's own Shift and Caps Lock flags rather than the event's
        // text, which is worked out from the keyboard's state when the event was made and can lag a synthetic Shift.
        var state: UInt32 = 0
        if event.flags.contains(.maskShift) { state |= UInt32(shiftKey) }
        if event.flags.contains(.maskAlphaShift) { state |= UInt32(alphaLock) }
        var typed = Self.translate(keyCode, modifierState: state)
        if typed.isEmpty {
            var length = 0
            var chars = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
            typed = String(utf16CodeUnits: chars, count: length)
        }
        guard let press = KeyNames.press(keyCode: keyCode, modifiers: modifiers, typed: typed, baseKey: Self.translate(keyCode)) else { return }
        timeline.key(press, at: CACurrentMediaTime())
        refreshKeys()
    }

    private func refreshKeys() {
        let labels = timeline.recentKeyLabels(at: CACurrentMediaTime())
        guard labels != shownLabels else { return }
        shownLabels = labels
        view.showKeys(labels)
    }

    /// What the key types in the current layout with these Carbon modifiers (none by default, so ⌘⇧4 reads "⇧⌘4" and not "⇧⌘$").
    private static func translate(_ keyCode: UInt16, modifierState: UInt32 = 0) -> String {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDown), (modifierState >> 8) & 0xFF, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        return status == noErr ? String(utf16CodeUnits: chars, count: length) : ""
    }
}

/// Click ripples, a dot while a button is held, and the key chips along the bottom. Top-left origin.
final class InputOverlayView: NSView {
    private let root = CALayer()
    private let heldDot = CALayer()
    private let keyRow = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer = root
        wantsLayer = true
        root.isGeometryFlipped = true
        root.frame = bounds
        heldDot.bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
        heldDot.cornerRadius = 11
        heldDot.opacity = 0
        root.addSublayer(heldDot)
        root.addSublayer(keyRow)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private static func color(for button: MouseButton) -> NSColor {
        switch button {
        case .left: NSColor(srgbRed: 1, green: 0.16, blue: 0.56, alpha: 1) // Snap It's hot pink
        case .right: .systemBlue
        case .other: .systemOrange
        }
    }

    func pressed(at point: CGPoint, button: MouseButton) {
        let color = Self.color(for: button)
        let ring = CAShapeLayer()
        let radius: CGFloat = 22
        ring.frame = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        ring.path = CGPath(ellipseIn: ring.bounds, transform: nil)
        ring.fillColor = color.withAlphaComponent(0.25).cgColor
        ring.strokeColor = color.cgColor
        ring.lineWidth = 3
        root.addSublayer(ring)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.4
        grow.toValue = 1.5
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.55
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.opacity = 0
        ring.add(group, forKey: "ripple")
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        heldDot.backgroundColor = color.withAlphaComponent(0.55).cgColor
        heldDot.position = point
        heldDot.opacity = 1
        CATransaction.commit()
    }

    func dragged(to point: CGPoint) {
        guard heldDot.opacity > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        heldDot.position = point
        CATransaction.commit()
    }

    func released() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        heldDot.opacity = 0
        CATransaction.commit()
    }

    /// The chips, centred along the bottom. The oldest drop off if they don't fit.
    func showKeys(_ labels: [String]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        keyRow.sublayers?.forEach { $0.removeFromSuperlayer() }
        let fontSize = min(24, max(13, bounds.height / 16))
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let padX = fontSize * 0.6, padY = fontSize * 0.35, gap = fontSize * 0.35
        var chips: [(NSAttributedString, CGSize)] = labels.map { label in
            let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.white])
            let size = text.size()
            return (text, CGSize(width: ceil(size.width) + padX * 2, height: ceil(size.height) + padY * 2))
        }
        func totalWidth() -> CGFloat { chips.map(\.1.width).reduce(0, +) + gap * CGFloat(max(chips.count - 1, 0)) }
        while chips.count > 1, totalWidth() > bounds.width - 16 { chips.removeFirst() }
        let height = chips.map(\.1.height).max() ?? 0
        var x = (bounds.width - totalWidth()) / 2
        let y = bounds.height - height - min(24, bounds.height * 0.06)
        let scale = window?.backingScaleFactor ?? 2
        for (text, size) in chips {
            let chip = CALayer()
            chip.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            chip.backgroundColor = NSColor(white: 0.08, alpha: 0.82).cgColor
            chip.cornerRadius = fontSize * 0.4
            chip.borderWidth = 1
            chip.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
            // CATextLayer draws from the top; nudge the text down to centre it.
            let inner = CATextLayer()
            inner.string = text
            inner.alignmentMode = .center
            inner.contentsScale = scale
            inner.frame = CGRect(x: 0, y: padY, width: size.width, height: size.height - padY)
            chip.addSublayer(inner)
            keyRow.addSublayer(chip)
            x += size.width + gap
        }
        CATransaction.commit()
    }
}
