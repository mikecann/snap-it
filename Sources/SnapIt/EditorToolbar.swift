import AppKit
import SnapItCore

func symbol(_ names: String..., description: String) -> NSImage? {
    for name in names {
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: description) { return image }
    }
    return nil
}

/// CleanShot-style strip above the canvas: tools, colour, size, undo/redo, drag-out, Copy, Save, Done.
@MainActor
final class EditorToolbar: NSView {
    weak var controller: EditorWindowController?
    let dragOut = DragOutView(frame: CGRect(x: 0, y: 0, width: 30, height: 28))
    private let tools: NSSegmentedControl
    private let colorWell = NSColorWell(style: .minimal)
    private let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let undoButton: NSButton
    private let redoButton: NSButton
    private let stack = NSStackView()
    private var sizeIsText = false

    static let toolOrder: [Tool] = [.arrow, .rectangle, .filledRectangle, .ellipse, .line, .text, .pen, .highlighter, .pixelate, .crop]
    static let thicknesses: [CGFloat] = [1, 2, 3, 5, 7, 10, 14, 20, 28]
    static let textSizes: [CGFloat] = [12, 16, 20, 24, 30, 35, 42, 48, 64, 80, 96]

    private static func image(for tool: Tool) -> NSImage? {
        switch tool {
        case .arrow: symbol("arrow.up.right", description: tool.title)
        case .rectangle: symbol("rectangle", description: tool.title)
        case .filledRectangle: symbol("rectangle.fill", description: tool.title)
        case .ellipse: symbol("circle", description: tool.title)
        case .line: symbol("line.diagonal", "minus", description: tool.title)
        case .text: symbol("textformat", "character", description: tool.title)
        case .pen: symbol("pencil.tip", "pencil", description: tool.title)
        case .highlighter: symbol("highlighter", "paintbrush.pointed", description: tool.title)
        case .pixelate: symbol("checkerboard.rectangle", "square.grid.3x3.fill", description: tool.title)
        case .crop: symbol("crop", description: tool.title)
        }
    }

    init() {
        let images = Self.toolOrder.map { Self.image(for: $0) ?? NSImage() }
        tools = NSSegmentedControl(images: images, trackingMode: .selectOne, target: nil, action: nil)
        undoButton = NSButton(image: symbol("arrow.uturn.backward", description: "Undo") ?? NSImage(), target: nil, action: nil)
        redoButton = NSButton(image: symbol("arrow.uturn.forward", description: "Redo") ?? NSImage(), target: nil, action: nil)
        super.init(frame: CGRect(x: 0, y: 0, width: 900, height: EditorWindowController.toolbarHeight))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        for (i, tool) in Self.toolOrder.enumerated() {
            tools.setToolTip("\(tool.title) (\(String(tool.shortcut).uppercased()))", forSegment: i)
            tools.setWidth(32, forSegment: i)
        }
        tools.segmentStyle = .separated
        tools.target = self
        tools.action = #selector(toolClicked)

        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        colorWell.toolTip = "Colour"
        colorWell.widthAnchor.constraint(equalToConstant: 38).isActive = true

        sizePopup.target = self
        sizePopup.action = #selector(sizeChanged)
        sizePopup.controlSize = .regular
        sizePopup.toolTip = "Thickness"

        for (button, action, tip) in [(undoButton, #selector(EditorWindowController.editorUndo(_:)), "Undo (⌘Z)"),
                                      (redoButton, #selector(EditorWindowController.editorRedo(_:)), "Redo (⌘⇧Z)")] {
            button.bezelStyle = .texturedRounded
            button.action = action
            button.toolTip = tip
        }

        dragOut.toolTip = "Drag the image into another app"
        dragOut.widthAnchor.constraint(equalToConstant: 30).isActive = true
        dragOut.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let copy = textButton("Copy", symbol: "doc.on.doc", action: #selector(EditorWindowController.editorCopy(_:)), tip: "Copy (⌘C)")
        let save = textButton("Save", symbol: "square.and.arrow.down", action: #selector(EditorWindowController.editorSave(_:)), tip: "Save (⌘S)")
        let done = NSButton(title: "Done", target: nil, action: #selector(EditorWindowController.editorDone(_:)))
        done.bezelStyle = .rounded
        done.bezelColor = .controlAccentColor
        done.toolTip = "Save, copy and close (⌘↩)"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        for view in [tools, colorWell, sizePopup, separator(), undoButton, redoButton, spacer, dragOut, copy, save, done] as [NSView] {
            stack.addArrangedSubview(view)
        }
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let line = NSBox()
        line.boxType = .separator
        line.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        line.autoresizingMask = [.width, .maxYMargin]
        addSubview(line)
        fillSizes(text: false, selected: 7)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        CGSize(width: stack.fittingSize.width, height: EditorWindowController.toolbarHeight)
    }

    private func textButton(_ title: String, symbol name: String, action: Selector, tip: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: action)
        button.image = symbol(name, description: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .texturedRounded
        button.toolTip = tip
        return button
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 1).isActive = true
        box.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return box
    }

    private func fillSizes(text: Bool, selected: CGFloat) {
        var values = text ? Self.textSizes : Self.thicknesses
        if !values.contains(selected) { values.append(selected); values.sort() }
        sizePopup.removeAllItems()
        for v in values {
            let title = v == v.rounded() ? "\(Int(v)) pt" : String(format: "%.1f pt", v)
            sizePopup.addItem(withTitle: title)
            sizePopup.lastItem?.representedObject = Double(v)
        }
        if let index = values.firstIndex(of: selected) { sizePopup.selectItem(at: index) }
        sizePopup.toolTip = text ? "Text size" : "Thickness"
    }

    func update(tool: Tool, color: RGBAColor, sizeIsText: Bool, size: CGFloat, canUndo: Bool, canRedo: Bool) {
        if let index = Self.toolOrder.firstIndex(of: tool) { tools.selectedSegment = index }
        let ns = NSColor(cgColor: color.cgColor) ?? .systemPink
        if colorWell.color != ns { colorWell.color = ns }
        fillSizes(text: sizeIsText, selected: size)
        self.sizeIsText = sizeIsText
        undoButton.isEnabled = canUndo
        redoButton.isEnabled = canRedo
    }

    @objc private func toolClicked() {
        let index = tools.selectedSegment
        guard Self.toolOrder.indices.contains(index) else { return }
        controller?.selectTool(Self.toolOrder[index])
    }

    @objc private func colorChanged() {
        guard let c = colorWell.color.usingColorSpace(.sRGB) else { return }
        controller?.colorPicked(RGBAColor(red: c.redComponent, green: c.greenComponent, blue: c.blueComponent, alpha: c.alphaComponent))
    }

    @objc private func sizeChanged() {
        guard let value = sizePopup.selectedItem?.representedObject as? Double else { return }
        controller?.sizePicked(CGFloat(value))
    }
}

/// Drag this into Claude, Slack or Finder to drop the annotated PNG as a file.
final class DragOutView: NSView, NSDraggingSource {
    var provider: (() -> (URL, NSImage)?)?
    private var dragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        let icon = NSImageView(image: symbol("photo.on.rectangle", "photo", description: "Drag out") ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        icon.contentTintColor = .labelColor
        icon.frame = bounds
        icon.autoresizingMask = [.width, .height]
        icon.unregisterDraggedTypes()
        addSubview(icon)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
    }

    // The icon must not swallow the drag.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let (url, image) = provider?() else { return }
        dragging = true
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let thumbWidth: CGFloat = 120
        let ratio = image.size.width > 0 ? image.size.height / image.size.width : 1
        let thumb = CGSize(width: thumbWidth, height: max(thumbWidth * ratio, 20))
        let location = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: location.x - thumb.width / 2, y: location.y - thumb.height / 2, width: thumb.width, height: thumb.height), contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
    }
}
