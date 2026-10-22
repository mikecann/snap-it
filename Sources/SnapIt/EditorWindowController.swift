import AppKit
import SnapItCore

/// One annotation window for one screenshot. Several can be open at once.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let model: AnnotationDocument
    let renderer: AnnotationRenderer
    /// Where saves go: the capture's PNG, or for an opened file the file itself or a sibling PNG.
    let fileURL: URL
    let scale: CGFloat
    private let settings: SnapItSettings
    private let canvas: CanvasView
    private let toolbar: EditorToolbar
    var onClose: ((EditorWindowController) -> Void)?
    /// Done or close is waiting for its write; the window is hidden until it lands.
    private var closing = false

    static let toolbarHeight: CGFloat = 46

    /// `sourceURL` is the file that was opened, when that isn't `fileURL`; it names the window.
    init(image: CGImage, scale: CGFloat, fileURL: URL, sourceURL: URL? = nil, screen: NSScreen, settings: SnapItSettings) {
        self.fileURL = fileURL
        self.scale = scale
        self.settings = settings
        renderer = AnnotationRenderer(baseImage: image, scale: scale)
        model = AnnotationDocument(imageSize: renderer.imageSize)
        canvas = CanvasView(document: model, renderer: renderer)
        toolbar = EditorToolbar()

        let toolbarWidth = toolbar.fittingSize.width
        let visible = screen.visibleFrame
        let maxSize = CGSize(width: visible.width * 0.85, height: visible.height * 0.85 - Self.toolbarHeight)
        let imageSize = renderer.imageSize
        let fit = min(1, maxSize.width / max(imageSize.width, 1), maxSize.height / max(imageSize.height, 1))
        let contentSize = CGSize(width: max(ceil(imageSize.width * fit), toolbarWidth, 360),
                                 height: max(ceil(imageSize.height * fit), 120) + Self.toolbarHeight)
        let window = EditorWindow(contentRect: CGRect(origin: .zero, size: contentSize),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        let shownURL = sourceURL ?? fileURL
        window.title = shownURL.deletingPathExtension().lastPathComponent
        window.representedURL = shownURL
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.contentMinSize = CGSize(width: min(toolbarWidth, 520), height: 160)
        window.backgroundColor = NSColor(white: 0.16, alpha: 1)

        let container = NSView(frame: CGRect(origin: .zero, size: contentSize))
        toolbar.frame = CGRect(x: 0, y: contentSize.height - Self.toolbarHeight, width: contentSize.width, height: Self.toolbarHeight)
        toolbar.autoresizingMask = [.width, .minYMargin]
        canvas.frame = CGRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height - Self.toolbarHeight)
        canvas.autoresizingMask = [.width, .height]
        container.addSubview(canvas)
        container.addSubview(toolbar)
        window.contentView = container
        let origin = CGPoint(x: visible.midX - contentSize.width / 2, y: visible.midY - contentSize.height / 2)
        window.setFrameOrigin(CGPoint(x: max(origin.x, visible.minX), y: max(origin.y, visible.minY)))

        super.init(window: window)
        window.delegate = self
        canvas.controller = self
        canvas.color = settings.color
        canvas.thickness = settings.thickness
        canvas.textSize = settings.textSize
        canvas.tool = settings.lastTool
        toolbar.controller = self
        toolbar.dragOut.provider = { [weak self] in self?.prepareDragFile() }
        refreshToolbar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
    }

    // MARK: Toolbar and canvas plumbing

    func selectTool(_ tool: Tool) {
        canvas.tool = tool
        canvas.refocus()
    }

    /// Called by the canvas whenever its tool, selection or text editing changes.
    func canvasStateChanged() {
        if canvas.tool != .crop { settings.lastTool = canvas.tool }
        refreshToolbar()
    }

    func refreshToolbar() {
        toolbar.update(tool: canvas.tool, color: canvas.styleColor, sizeIsText: canvas.isTextContext,
                       size: canvas.isTextContext ? canvas.styleTextSize : canvas.styleThickness,
                       canUndo: model.canUndo || canvas.isEditingText, canRedo: model.canRedo)
    }

    func colorPicked(_ color: RGBAColor) {
        canvas.applyColor(color)
        settings.color = color
        refreshToolbar()
        canvas.refocus()
    }

    func sizePicked(_ value: CGFloat) {
        if canvas.isTextContext { settings.textSize = value } else { settings.thickness = value }
        canvas.applySize(value)
        refreshToolbar()
        canvas.refocus()
    }

    // MARK: Commands

    @objc func editorUndo(_ sender: Any?) {
        if canvas.isEditingText {
            window?.undoManager?.undo()
            return
        }
        canvas.undo()
    }

    @objc func editorRedo(_ sender: Any?) {
        if canvas.isEditingText {
            window?.undoManager?.redo()
            return
        }
        canvas.redo()
    }

    @objc func editorSave(_ sender: Any?) { save() }
    @objc func editorDone(_ sender: Any?) { done() }
    @objc func editorCopy(_ sender: Any?) { copyImage() }

    /// Flatten, overwrite the PNG, copy it and close. With nothing new to write it just copies and closes.
    func done() {
        guard !closing else { return }
        canvas.finishInteractions()
        if model.hasUnsavedChanges {
            closeAfterWriting()
        } else {
            copyImage(withFile: FileManager.default.fileExists(atPath: fileURL.path))
            window?.close()
        }
    }

    func save() {
        guard !closing else { return }
        canvas.finishInteractions()
        writeFlattened(copy: false)
    }

    /// Copies the flattened image and keeps the window open. The file isn't updated, so only image data goes on the clipboard.
    func copyImage() {
        canvas.finishInteractions()
        copyImage(withFile: false)
    }

    private func copyImage(withFile: Bool) {
        guard let image = renderer.flatten(model.state) else { return }
        let scale = scale, url = withFile ? fileURL : nil
        Output.io.async {
            let data = PNGWriter.data(for: image, scale: scale)
            DispatchQueue.main.async { if let data { Output.copyToClipboard(png: data, fileURL: url) } }
        }
    }

    /// Hides the window straight away, writes, then closes. If the write fails the window comes back, still unsaved.
    private func closeAfterWriting() {
        closing = true
        window?.orderOut(nil)
        writeFlattened(copy: true, closeWhenSaved: true)
    }

    /// The document only counts as saved once the write has landed.
    private func writeFlattened(copy: Bool, closeWhenSaved: Bool = false) {
        let start = CACurrentMediaTime()
        guard let image = renderer.flatten(model.state) else {
            saveFailed(data: nil)
            return
        }
        let state = model.state
        let url = fileURL
        Output.write(image, scale: scale, to: url) { [self] result in
            guard result.saved, let data = result.data else {
                saveFailed(data: result.data)
                return
            }
            model.markSaved(state)
            if copy { Output.copyToClipboard(png: data, fileURL: url) }
            Log.info("Saved annotated \(url.lastPathComponent)\(copy ? " and copied it" : "") in \(Log.ms(since: start))")
            if closeWhenSaved {
                closing = false
                window?.close()
            }
        }
    }

    /// Never lose the work: the image goes on the clipboard, the editor stays open and unsaved, and an alert says why.
    func saveFailed(data: Data?) {
        closing = false
        model.markNeedsSave()
        if let data { Output.copyToClipboard(png: data, fileURL: nil) }
        Log.info("Save to \(fileURL.path) failed; \(data != nil ? "copied the image instead and " : "")kept the editor open")
        guard let window else { return }
        if !window.isVisible { present() }
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't save \(fileURL.lastPathComponent)"
        alert.informativeText = (data != nil ? "The annotated image is on the clipboard. " : "")
            + "Check that \(fileURL.deletingLastPathComponent().path) exists and has space, then press Save or Done again."
        alert.beginSheetModal(for: window)
    }

    /// Before the app quits: writes unsaved changes now, on this thread. Nil if there was nothing to write.
    func commitNow() -> Output.WriteResult? {
        canvas.finishInteractions()
        guard model.hasUnsavedChanges, let image = renderer.flatten(model.state) else { return nil }
        let result = Output.writeNow(image, scale: scale, to: fileURL)
        if result.saved { model.markSaved() }
        return result
    }

    /// Writes the flattened image to the saved path so it can be dragged out as a file.
    func prepareDragFile() -> (URL, NSImage)? {
        canvas.finishInteractions()
        let state = model.state
        guard let image = renderer.flatten(state), Output.writeNow(image, scale: scale, to: fileURL).saved else { return nil }
        model.markSaved(state)
        let preview = NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
        return (fileURL, preview)
    }

    // MARK: NSWindowDelegate

    /// Closing never loses annotations: unsaved changes are committed exactly like Done.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closing else { return false }
        canvas.finishInteractions()
        guard model.hasUnsavedChanges else { return true }
        closeAfterWriting()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}

final class EditorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
