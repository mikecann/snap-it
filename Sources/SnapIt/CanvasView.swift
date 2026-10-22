import AppKit
import SnapItCore

/// Shows the screenshot and its live annotations, and turns mouse and keys into document changes.
/// Drawing goes through the same `AnnotationRenderer` as export.
@MainActor
final class CanvasView: NSView, NSTextViewDelegate {
    let document: AnnotationDocument
    let renderer: AnnotationRenderer
    weak var controller: EditorWindowController?

    var tool: Tool = .arrow {
        didSet { toolChanged(from: oldValue) }
    }
    var color: RGBAColor = .hotPink
    var thickness: CGFloat = 7
    var textSize: CGFloat = 35

    private(set) var selectedID: UUID? {
        didSet { if oldValue != selectedID { needsDisplay = true; controller?.canvasStateChanged() } }
    }

    private enum Gesture {
        case creating(id: UUID, start: CGPoint)
        case moving(id: UUID, last: CGPoint)
        /// `anchor` is the point that stays fixed for the whole drag.
        case handle(id: UUID, index: Int, anchor: CGPoint?)
        case cropNew(start: CGPoint)
        case cropMove(last: CGPoint)
        case cropHandle(CropHandle)
    }

    private var gesture: Gesture?
    private var gestureStart: EditorState?
    private var cropGestureStart: CGRect?
    private(set) var pendingCrop: CGRect?
    private var toolBeforeCrop: Tool = .arrow
    private var textView: NSTextView?
    private var editingID: UUID?
    private var editingStart: EditorState?

    init(document: AnnotationDocument, renderer: AnnotationRenderer) {
        self.document = document
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var isEditingText: Bool { editingID != nil }

    /// Toolbar clicks can take focus; give it back so tool keys and typing keep working.
    func refocus() {
        window?.makeFirstResponder(textView ?? self)
    }
    var selectedAnnotation: Annotation? { selectedID.flatMap { document.annotation(id: $0) } }

    /// Text tool, a selected text box or text being typed: the size control means font size.
    var isTextContext: Bool { tool == .text || isEditingText || selectedAnnotation?.kind == .text }
    var styleColor: RGBAColor { selectedAnnotation?.color ?? color }
    var styleThickness: CGFloat { selectedAnnotation.map { $0.kind == .text ? thickness : $0.thickness } ?? thickness }
    var styleTextSize: CGFloat { selectedAnnotation.map { $0.kind == .text ? $0.fontSize : textSize } ?? textSize }

    // MARK: Coordinates

    private var visibleImageRect: CGRect { pendingCrop != nil ? document.imageBounds : (document.state.crop ?? document.imageBounds) }
    private var margin: CGFloat { pendingCrop != nil ? 16 : 0 }

    private var zoom: CGFloat {
        let v = visibleImageRect, area = bounds.insetBy(dx: margin, dy: margin)
        guard v.width > 0, v.height > 0, area.width > 0, area.height > 0 else { return 1 }
        return min(area.width / v.width, area.height / v.height, 1)
    }

    private var imageOrigin: CGPoint {
        let v = visibleImageRect, z = zoom
        return CGPoint(x: ((bounds.width - v.width * z) / 2).rounded(), y: ((bounds.height - v.height * z) / 2).rounded())
    }

    private func toImage(_ p: CGPoint) -> CGPoint {
        let z = zoom, o = imageOrigin, v = visibleImageRect
        return CGPoint(x: (p.x - o.x) / z + v.minX, y: (p.y - o.y) / z + v.minY)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let z = zoom, o = imageOrigin, v = visibleImageRect
        return CGPoint(x: (p.x - v.minX) * z + o.x, y: (p.y - v.minY) * z + o.y)
    }

    private func toView(_ r: CGRect) -> CGRect {
        let a = toView(CGPoint(x: r.minX, y: r.minY)), b = toView(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        toImage(convert(event.locationInWindow, from: nil))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutTextView()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(white: 0.16, alpha: 1).setFill()
        bounds.fill()
        let v = visibleImageRect, z = zoom, o = imageOrigin
        ctx.saveGState()
        ctx.translateBy(x: o.x, y: o.y)
        ctx.scaleBy(x: z, y: z)
        ctx.translateBy(x: -v.minX, y: -v.minY)
        ctx.clip(to: v)
        ctx.interpolationQuality = z < 1 ? .high : .none
        renderer.drawBase(in: ctx)
        ctx.interpolationQuality = .high
        renderer.draw(document.state, in: ctx, skipping: editingID)
        ctx.restoreGState()

        if let crop = pendingCrop {
            drawCropOverlay(crop)
        } else if let a = selectedAnnotation, a.id != editingID {
            drawSelection(a)
        }
    }

    private func drawSelection(_ a: Annotation) {
        let handles = a.handles
        if handles.isEmpty {
            let box = NSBezierPath(rect: toView(a.bounds).insetBy(dx: -4, dy: -4))
            box.lineWidth = 1
            box.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.white.setStroke()
            box.stroke()
            NSColor.black.withAlphaComponent(0.5).setStroke()
            box.setLineDash([4, 3], count: 2, phase: 3.5)
            box.stroke()
            return
        }
        for p in handles { drawHandle(at: toView(p)) }
    }

    private func drawHandle(at p: CGPoint, square: Bool = false) {
        let r = CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)
        let path = square ? NSBezierPath(rect: r.insetBy(dx: 1, dy: 1)) : NSBezierPath(ovalIn: r)
        NSColor.white.setFill()
        path.fill()
        path.lineWidth = 1.5
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private func drawCropOverlay(_ crop: CGRect) {
        let image = toView(document.imageBounds), cropRect = toView(crop)
        let dim = NSBezierPath(rect: image)
        dim.append(NSBezierPath(rect: cropRect))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill()
        dim.fill()
        let border = NSBezierPath(rect: cropRect)
        border.lineWidth = 1.5
        NSColor.white.setStroke()
        border.stroke()
        // Rule-of-thirds guides.
        let guides = NSBezierPath()
        for i in 1...2 {
            let x = cropRect.minX + cropRect.width * CGFloat(i) / 3, y = cropRect.minY + cropRect.height * CGFloat(i) / 3
            guides.move(to: CGPoint(x: x, y: cropRect.minY)); guides.line(to: CGPoint(x: x, y: cropRect.maxY))
            guides.move(to: CGPoint(x: cropRect.minX, y: y)); guides.line(to: CGPoint(x: cropRect.maxX, y: y))
        }
        guides.lineWidth = 0.5
        NSColor.white.withAlphaComponent(0.4).setStroke()
        guides.stroke()
        for handle in CropHandle.allCases { drawHandle(at: handle.point(in: cropRect), square: true) }
        let pixels = "\(Int((crop.width * renderer.scale).rounded())) × \(Int((crop.height * renderer.scale).rounded()))  ·  Return to crop, Esc to cancel"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let size = (pixels as NSString).size(withAttributes: attributes)
        let labelRect = CGRect(x: cropRect.minX, y: max(cropRect.minY - size.height - 8, 2), width: size.width + 12, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
        (pixels as NSString).draw(at: CGPoint(x: labelRect.minX + 6, y: labelRect.minY + 2), withAttributes: attributes)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .text ? .iBeam : .crosshair)
    }

    // MARK: Tools

    private func toolChanged(from old: Tool) {
        if tool == .crop, old != .crop {
            endTextEditing()
            toolBeforeCrop = old
            selectedID = nil
            pendingCrop = document.state.crop ?? document.imageBounds
        } else if old == .crop, tool != .crop {
            applyPendingCrop()
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        controller?.canvasStateChanged()
    }

    private func applyPendingCrop() {
        guard let crop = pendingCrop else { return }
        pendingCrop = nil
        var s = document.state
        s.crop = CropMath.normalized(crop, imageBounds: document.imageBounds, scale: renderer.scale)
        document.commit(s)
        needsDisplay = true
        controller?.canvasStateChanged()
    }

    private func cancelCrop() {
        pendingCrop = nil
        tool = toolBeforeCrop
    }

    /// Ends text editing and applies a pending crop, before export or closing.
    func finishInteractions() {
        endTextEditing()
        if gesture != nil { gesture = nil; gestureStart.map { document.commit(document.state, from: $0) }; gestureStart = nil }
        if pendingCrop != nil {
            applyPendingCrop()
            tool = toolBeforeCrop
        }
    }

    func applyColor(_ c: RGBAColor) {
        color = c
        if let id = editingID, var a = document.annotation(id: id) {
            a.color = c
            document.setLive(AnnotationDocument.replacing(a, in: document.state))
            textView?.textColor = NSColor(cgColor: c.cgColor)
            textView?.insertionPointColor = NSColor(cgColor: c.cgColor) ?? .systemPink
            return
        }
        if var a = selectedAnnotation, a.color != c {
            a.color = c
            document.update(a)
        }
        needsDisplay = true
    }

    func applySize(_ value: CGFloat) {
        if isTextContext { textSize = value } else { thickness = value }
        if let id = editingID, var a = document.annotation(id: id) {
            a.fontSize = value
            document.setLive(AnnotationDocument.replacing(a, in: document.state))
            textView?.font = TextStyle.font(size: value * zoom)
            layoutTextView()
            return
        }
        if var a = selectedAnnotation {
            if a.kind == .text { a.fontSize = value } else { a.thickness = value }
            document.update(a)
        }
        needsDisplay = true
    }

    func undo() {
        finishInteractions()
        document.undo()
        dropStaleSelection()
    }

    func redo() {
        finishInteractions()
        document.redo()
        dropStaleSelection()
    }

    private func dropStaleSelection() {
        if let id = selectedID, document.annotation(id: id) == nil { selectedID = nil }
        needsDisplay = true
        controller?.canvasStateChanged()
    }

    func deleteSelection() {
        guard let id = selectedID else { return }
        selectedID = nil
        document.remove(id: id)
        needsDisplay = true
        controller?.canvasStateChanged()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if isEditingText {
            // Clicking anywhere outside the text box ends editing.
            endTextEditing()
            return
        }
        window?.makeFirstResponder(self)
        let p = imagePoint(event)
        if tool == .crop {
            cropMouseDown(at: p)
            return
        }
        gestureStart = document.state
        if let selected = selectedAnnotation,
           let index = selected.handles.firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) <= 8 / zoom }) {
            gesture = .handle(id: selected.id, index: index, anchor: selected.anchor(forHandle: index))
            return
        }
        if let hit = document.topmostAnnotation(at: p, tolerance: 5 / zoom) {
            selectedID = hit.id
            if hit.kind == .text, tool == .text || event.clickCount >= 2 {
                gestureStart = nil
                beginTextEditing(existing: hit)
                return
            }
            gesture = .moving(id: hit.id, last: p)
            return
        }
        selectedID = nil
        if tool == .text {
            gestureStart = nil
            beginTextEditing(at: p)
            return
        }
        guard let kind = tool.shapeKind else { return }
        let a = Annotation(kind: kind, points: kind.isFreehand ? [p] : [p, p], color: color, thickness: thickness, fontSize: textSize)
        document.setLive(AnnotationDocument.replacing(a, in: document.state))
        gesture = .creating(id: a.id, start: p)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let gesture else { return }
        let p = imagePoint(event)
        let shift = event.modifierFlags.contains(.shift)
        switch gesture {
        case let .creating(id, start):
            guard var a = document.annotation(id: id) else { return }
            switch a.kind {
            case .arrow, .line:
                a.points = [start, shift ? ShapePaths.snap45(from: start, to: p) : p]
            case .rectangle, .filledRectangle, .ellipse, .pixelate:
                a.points = [start, shift ? ShapePaths.squared(from: start, to: p) : p]
            case .pen:
                if let last = a.points.last, hypot(last.x - p.x, last.y - p.y) >= 1 / zoom { a.points.append(p) }
            case .highlighter:
                if shift {
                    a.points = [start, CGPoint(x: p.x, y: start.y)]
                } else if let last = a.points.last, hypot(last.x - p.x, last.y - p.y) >= 1 / zoom {
                    a.points.append(p)
                }
            case .text:
                return
            }
            document.setLive(AnnotationDocument.replacing(a, in: document.state))
        case let .moving(id, last):
            guard let a = document.annotation(id: id) else { return }
            document.setLive(AnnotationDocument.replacing(a.offsetBy(dx: p.x - last.x, dy: p.y - last.y), in: document.state))
            self.gesture = .moving(id: id, last: p)
        case let .handle(id, index, anchor):
            guard let a = document.annotation(id: id) else { return }
            var target = p
            if shift, let anchor {
                switch a.kind {
                case .arrow, .line: target = ShapePaths.snap45(from: anchor, to: p)
                case .rectangle, .filledRectangle, .ellipse, .pixelate: target = ShapePaths.squared(from: anchor, to: p)
                default: break
                }
            }
            document.setLive(AnnotationDocument.replacing(a.movingHandle(index, to: target, anchor: anchor), in: document.state))
        case let .cropNew(start):
            pendingCrop = SelectionMath.rect(from: start, to: p, square: shift, within: document.imageBounds)
        case let .cropMove(last):
            guard let crop = pendingCrop else { return }
            pendingCrop = CropMath.move(crop, by: CGSize(width: p.x - last.x, height: p.y - last.y), within: document.imageBounds)
            self.gesture = .cropMove(last: p)
        case let .cropHandle(handle):
            guard let crop = pendingCrop else { return }
            pendingCrop = CropMath.resize(crop, handle: handle, to: p, within: document.imageBounds)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            gesture = nil
            gestureStart = nil
            cropGestureStart = nil
            needsDisplay = true
            controller?.canvasStateChanged()
        }
        guard let gesture else { return }
        switch gesture {
        case let .creating(id, _):
            guard let start = gestureStart else { return }
            if let a = document.annotation(id: id), !a.isDegenerate {
                document.commit(document.state, from: start)
            } else {
                document.setLive(start)
            }
        case .moving, .handle:
            if let start = gestureStart { document.commit(document.state, from: start) }
        case .cropNew:
            // A click without a drag keeps the previous crop rectangle.
            if let crop = pendingCrop, crop.width < CropMath.minimumSize || crop.height < CropMath.minimumSize {
                pendingCrop = cropGestureStart
            }
        case .cropMove, .cropHandle:
            break
        }
    }

    private func cropMouseDown(at p: CGPoint) {
        guard let crop = pendingCrop else { return }
        cropGestureStart = crop
        let reach = 10 / zoom
        if let handle = CropHandle.allCases.first(where: { let h = $0.point(in: crop); return hypot(h.x - p.x, h.y - p.y) <= reach }) {
            gesture = .cropHandle(handle)
        } else if crop.contains(p) {
            gesture = .cropMove(last: p)
        } else {
            gesture = .cropNew(start: SelectionMath.clamp(p, to: document.imageBounds))
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 51, 117: // Delete, Forward Delete
            deleteSelection()
            return
        case 36, 76: // Return, Enter
            if pendingCrop != nil {
                applyPendingCrop()
                tool = toolBeforeCrop
            } else {
                controller?.done()
            }
            return
        case 53: // Escape
            handleEscape()
            return
        case 123, 124, 125, 126:
            nudge(keyCode: event.keyCode, by: flags.contains(.shift) ? 10 : 1)
            return
        default:
            break
        }
        if flags.isDisjoint(with: [.command, .control, .option]),
           let c = event.charactersIgnoringModifiers?.first, let t = Tool(shortcut: c) {
            controller?.selectTool(t)
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) { handleEscape() }

    private func handleEscape() {
        if gesture != nil {
            if let start = gestureStart { document.setLive(start) }
            if let crop = cropGestureStart { pendingCrop = crop }
            gesture = nil
            gestureStart = nil
            needsDisplay = true
            return
        }
        if pendingCrop != nil { cancelCrop(); return }
        if selectedID != nil { selectedID = nil; return }
        window?.performClose(nil)
    }

    private func nudge(keyCode: UInt16, by step: CGFloat) {
        guard let a = selectedAnnotation else { return }
        let dx: CGFloat = keyCode == 123 ? -step : keyCode == 124 ? step : 0
        let dy: CGFloat = keyCode == 126 ? -step : keyCode == 125 ? step : 0
        document.update(a.offsetBy(dx: dx, dy: dy))
        needsDisplay = true
        controller?.canvasStateChanged()
    }

    /// ⌘C copies the flattened image when no text is being edited (the text view handles its own ⌘C).
    @objc func copy(_ sender: Any?) {
        controller?.copyImage()
    }

    @objc func delete(_ sender: Any?) {
        deleteSelection()
    }

    // MARK: Text

    private func beginTextEditing(at p: CGPoint) {
        let lineHeight = TextStyle.size(of: "", fontSize: textSize).height
        let a = Annotation(kind: .text, points: [CGPoint(x: p.x, y: p.y - lineHeight / 2)], color: color, thickness: thickness, fontSize: textSize)
        editingStart = document.state
        document.setLive(AnnotationDocument.replacing(a, in: document.state))
        startTextView(for: a)
    }

    private func beginTextEditing(existing a: Annotation) {
        editingStart = document.state
        startTextView(for: a)
    }

    private func startTextView(for a: Annotation) {
        editingID = a.id
        selectedID = a.id
        let tv = NSTextView(frame: .zero)
        tv.delegate = self
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.focusRingType = .none
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.font = TextStyle.font(size: a.fontSize * zoom)
        tv.textColor = NSColor(cgColor: a.color.cgColor)
        tv.insertionPointColor = NSColor(cgColor: a.color.cgColor) ?? .systemPink
        tv.string = a.text
        addSubview(tv)
        textView = tv
        layoutTextView()
        window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (a.text as NSString).length, length: 0))
        needsDisplay = true
        controller?.canvasStateChanged()
    }

    private func layoutTextView() {
        guard let tv = textView, let id = editingID, let a = document.annotation(id: id) else { return }
        let size = TextStyle.size(of: tv.string, fontSize: a.fontSize)
        let origin = toView(a.points[0])
        // The window may have been resized mid-edit, which changes the zoom.
        let font = TextStyle.font(size: a.fontSize * zoom)
        if tv.font?.pointSize != font.pointSize { tv.font = font }
        tv.frame = CGRect(x: origin.x, y: origin.y, width: size.width * zoom + 4, height: size.height * zoom)
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = textView, let id = editingID, var a = document.annotation(id: id) else { return }
        a.text = tv.string
        document.setLive(AnnotationDocument.replacing(a, in: document.state))
        layoutTextView()
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            endTextEditing()
            return true
        }
        return false
    }

    /// Commits the typed text as one undo step. Empty text removes the box.
    private func endTextEditing() {
        guard let tv = textView, let id = editingID, let start = editingStart else { return }
        textView = nil
        editingID = nil
        editingStart = nil
        var final = document.state
        if var a = document.annotation(id: id) {
            a.text = tv.string
            if a.isDegenerate {
                final.annotations.removeAll { $0.id == id }
            } else {
                final = AnnotationDocument.replacing(a, in: final)
            }
        }
        document.setLive(start)
        document.commit(final, from: start)
        tv.removeFromSuperview()
        window?.undoManager?.removeAllActions()
        window?.makeFirstResponder(self)
        selectedID = nil
        needsDisplay = true
        controller?.canvasStateChanged()
    }
}
