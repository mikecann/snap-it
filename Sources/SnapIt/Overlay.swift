import AppKit
import QuartzCore
import SnapItCore

/// The frozen, dimmed screen on every display while you drag out an area.
@MainActor
final class OverlayController {
    struct Selection {
        let capture: DisplayCapture
        let image: CGImage
        let localRect: CGRect
    }

    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private let completion: (Selection?) -> Void
    private var finished = false

    init(captures: [DisplayCapture], completion: @escaping (Selection?) -> Void) {
        self.completion = completion
        for capture in captures {
            let window = OverlayWindow(contentRect: capture.screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = true
            window.hasShadow = false
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            window.animationBehavior = .none
            let view = OverlayView(capture: capture, controller: self)
            window.contentView = view
            window.setFrame(capture.screen.frame, display: false)
            windows.append(window)
            views.append(view)
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        for window in windows { window.orderFrontRegardless() }
        let keyIndex = windows.firstIndex { NSMouseInRect(mouse, $0.frame, false) } ?? 0
        if windows.indices.contains(keyIndex) {
            windows[keyIndex].makeKey()
            windows[keyIndex].makeFirstResponder(views[keyIndex])
        }
        pointerMoved()
        NSCursor.crosshair.set()
    }

    func pointerMoved() {
        let mouse = NSEvent.mouseLocation
        for view in views { view.updatePointer(global: mouse) }
        NSCursor.crosshair.set()
    }

    func finish(view: OverlayView, localRect: CGRect) {
        let pixelRect = view.capture.mapping.pixelRect(fromLocal: localRect)
        guard pixelRect.width >= 1, pixelRect.height >= 1, let cropped = view.capture.image.cropping(to: pixelRect) else {
            cancel()
            return
        }
        close(with: Selection(capture: view.capture, image: cropped, localRect: localRect))
    }

    func cancel() {
        close(with: nil)
    }

    private func close(with selection: Selection?) {
        guard !finished else { return }
        finished = true
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
        completion(selection)
    }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Layer-hosting view (top-left origin) so moving the pointer only moves layers, never redraws a 5K image.
final class OverlayView: NSView {
    let capture: DisplayCapture
    private weak var controller: OverlayController?
    private let root = CALayer()
    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let horizontalLine = CALayer()
    private let verticalLine = CALayer()
    private let sizeLabel = CATextLayer()
    private let loupe = CALayer()
    private let loupeImage = CALayer()
    private let loupeGrid = CAShapeLayer()
    private let loupeCenter = CAShapeLayer()
    private let loupeLabel = CATextLayer()
    private var dragStart: CGPoint?
    private var selection: CGRect?

    private static let loupePixels = 15
    private static let loupeCell: CGFloat = 8
    private static var loupeSize: CGFloat { CGFloat(loupePixels) * loupeCell }
    private static let labelHeight: CGFloat = 20

    init(capture: DisplayCapture, controller: OverlayController) {
        self.capture = capture
        self.controller = controller
        super.init(frame: CGRect(origin: .zero, size: capture.screen.frame.size))
        layer = root
        wantsLayer = true
        buildLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func buildLayers() {
        let scale = capture.screen.backingScaleFactor
        let bounds = CGRect(origin: .zero, size: capture.screen.frame.size)
        root.isGeometryFlipped = true
        root.frame = bounds
        root.backgroundColor = NSColor.black.cgColor
        imageLayer.frame = bounds
        imageLayer.contents = capture.image
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest
        dimLayer.frame = bounds
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.3).cgColor
        dimLayer.fillRule = .evenOdd
        dimLayer.path = CGPath(rect: bounds, transform: nil)
        borderLayer.frame = bounds
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        borderLayer.lineWidth = 1
        for line in [horizontalLine, verticalLine] {
            line.backgroundColor = NSColor.white.withAlphaComponent(0.55).cgColor
            line.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
        }
        configure(label: sizeLabel, scale: scale)
        sizeLabel.isHidden = true

        loupe.frame = CGRect(x: 0, y: 0, width: Self.loupeSize, height: Self.loupeSize + Self.labelHeight)
        loupe.masksToBounds = true
        loupe.cornerRadius = 8
        loupe.borderWidth = 1.5
        loupe.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        loupe.backgroundColor = NSColor(white: 0.1, alpha: 0.9).cgColor
        loupeImage.frame = CGRect(x: 0, y: 0, width: Self.loupeSize, height: Self.loupeSize)
        loupeImage.magnificationFilter = .nearest
        loupeImage.contentsGravity = .resize
        loupeGrid.frame = loupeImage.frame
        let grid = CGMutablePath()
        for i in 1..<Self.loupePixels {
            let v = CGFloat(i) * Self.loupeCell
            grid.move(to: CGPoint(x: v, y: 0)); grid.addLine(to: CGPoint(x: v, y: Self.loupeSize))
            grid.move(to: CGPoint(x: 0, y: v)); grid.addLine(to: CGPoint(x: Self.loupeSize, y: v))
        }
        loupeGrid.path = grid
        loupeGrid.strokeColor = NSColor.black.withAlphaComponent(0.18).cgColor
        loupeGrid.lineWidth = 0.5
        let mid = CGFloat(Self.loupePixels / 2) * Self.loupeCell
        loupeCenter.frame = loupeImage.frame
        loupeCenter.path = CGPath(rect: CGRect(x: mid, y: mid, width: Self.loupeCell, height: Self.loupeCell), transform: nil)
        loupeCenter.fillColor = nil
        loupeCenter.strokeColor = NSColor.white.cgColor
        loupeCenter.lineWidth = 1.5
        configure(label: loupeLabel, scale: scale)
        loupeLabel.cornerRadius = 0
        loupeLabel.backgroundColor = nil
        loupeLabel.frame = CGRect(x: 0, y: Self.loupeSize + 2, width: Self.loupeSize, height: Self.labelHeight - 2)
        for sub in [loupeImage, loupeGrid, loupeCenter, loupeLabel] { loupe.addSublayer(sub) }

        for sub in [imageLayer, dimLayer, borderLayer, horizontalLine, verticalLine, sizeLabel, loupe] { root.addSublayer(sub) }
        horizontalLine.isHidden = true
        verticalLine.isHidden = true
        loupe.isHidden = true
    }

    private func configure(label: CATextLayer, scale: CGFloat) {
        label.contentsScale = scale
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.fontSize = 12
        label.foregroundColor = NSColor.white.cgColor
        label.backgroundColor = NSColor(white: 0, alpha: 0.7).cgColor
        label.cornerRadius = 5
        label.alignmentMode = .center
    }

    // MARK: Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate], owner: self))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { controller?.pointerMoved() }
    override func mouseEntered(with event: NSEvent) { controller?.pointerMoved() }
    override func mouseExited(with event: NSEvent) { controller?.pointerMoved() }

    func updatePointer(global: CGPoint) {
        guard dragStart == nil else { return }
        let inside = capture.mapping.contains(global: global)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        horizontalLine.isHidden = !inside
        verticalLine.isHidden = !inside
        loupe.isHidden = !inside
        if inside { place(pointer: capture.mapping.localPoint(fromGlobal: global)) }
        CATransaction.commit()
    }

    private func place(pointer p: CGPoint) {
        horizontalLine.frame = CGRect(x: 0, y: floor(p.y), width: bounds.width, height: 1)
        verticalLine.frame = CGRect(x: floor(p.x), y: 0, width: 1, height: bounds.height)
        let pixel = capture.mapping.pixelPoint(fromLocal: p)
        let px = Int(pixel.x.rounded(.down)), py = Int(pixel.y.rounded(.down))
        loupeImage.contents = loupeContents(centerX: px, centerY: py)
        if let selection {
            let size = capture.mapping.pixelRect(fromLocal: selection).size
            loupeLabel.string = "\(Int(size.width)) × \(Int(size.height))"
        } else {
            loupeLabel.string = "\(px), \(py)"
        }
        // Down-right of the pointer, flipping to stay on this display.
        let size = loupe.frame.size
        var origin = CGPoint(x: p.x + 24, y: p.y + 24)
        if origin.x + size.width > bounds.width { origin.x = p.x - 24 - size.width }
        if origin.y + size.height > bounds.height { origin.y = p.y - 24 - size.height }
        origin.x = min(max(origin.x, 0), max(bounds.width - size.width, 0))
        origin.y = min(max(origin.y, 0), max(bounds.height - size.height, 0))
        loupe.frame = CGRect(origin: origin, size: size)
    }

    /// The pixels around the pointer, padded with black at the display's edges.
    private func loupeContents(centerX: Int, centerY: Int) -> CGImage? {
        let n = Self.loupePixels, half = n / 2
        let wanted = CGRect(x: centerX - half, y: centerY - half, width: n, height: n)
        let available = wanted.intersection(CGRect(x: 0, y: 0, width: capture.image.width, height: capture.image.height))
        guard !available.isNull, let region = capture.image.cropping(to: available),
              let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: capture.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
        ctx.interpolationQuality = .none
        // CGContext is y-up, so the region's top-left offset becomes a bottom-left one.
        let dx = available.minX - wanted.minX
        let dy = wanted.maxY - available.maxY
        ctx.draw(region, in: CGRect(x: dx, y: dy, width: available.width, height: available.height))
        return ctx.makeImage()
    }

    // MARK: Selection

    private func localPoint(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = SelectionMath.clamp(localPoint(event), to: bounds)
        selection = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        horizontalLine.isHidden = true
        verticalLine.isHidden = true
        CATransaction.commit()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let current = localPoint(event)
        let rect = SelectionMath.rect(from: start, to: current, square: event.modifierFlags.contains(.shift), within: bounds)
        selection = rect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let dim = CGMutablePath()
        dim.addRect(bounds)
        dim.addRect(rect)
        dimLayer.path = dim
        borderLayer.path = CGPath(rect: rect.insetBy(dx: -0.5, dy: -0.5), transform: nil)
        let pixels = capture.mapping.pixelRect(fromLocal: rect).size
        let text = "\(Int(pixels.width)) × \(Int(pixels.height))"
        sizeLabel.string = text
        let labelSize = CGSize(width: max(80, CGFloat(text.count) * 8 + 16), height: 20)
        var labelOrigin = CGPoint(x: rect.minX, y: rect.minY - labelSize.height - 6)
        if labelOrigin.y < 0 { labelOrigin.y = rect.minY + 6 }
        labelOrigin.x = min(max(labelOrigin.x, 0), bounds.width - labelSize.width)
        sizeLabel.frame = CGRect(origin: labelOrigin, size: labelSize)
        sizeLabel.isHidden = false
        loupe.isHidden = false
        place(pointer: SelectionMath.clamp(current, to: bounds))
        horizontalLine.isHidden = true
        verticalLine.isHidden = true
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        // A plain click with no drag cancels.
        guard let rect = selection, rect.width >= 2, rect.height >= 2 else {
            controller?.cancel()
            return
        }
        controller?.finish(view: self, localRect: rect)
    }

    override func rightMouseDown(with event: NSEvent) { controller?.cancel() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { controller?.cancel() } // Escape
    }

    override func cancelOperation(_ sender: Any?) { controller?.cancel() }
}
