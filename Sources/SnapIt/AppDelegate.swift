import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SnapItCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = SnapItSettings()
    private let capturer = ScreenCapturer()
    private var statusItem: NSStatusItem?
    private var loginMenuItem: NSMenuItem?
    private var editors: [EditorWindowController] = []
    private var overlay: OverlayController?
    private var capturing = false
    private var reservedPaths: Set<String> = []
    private var permissionAlertShown: Date?
    private var previousApp: NSRunningApplication?
    private var terminationSignal: DispatchSourceSignal?
    private var launched = false
    /// Files and URLs that arrive before launch has finished.
    private var pendingOpens: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        Log.info("Snap It \(version) started (pid \(ProcessInfo.processInfo.processIdentifier), \(NSScreen.screens.count) displays)")
        NSApp.mainMenu = MainMenu.build()
        buildStatusItem()
        registerHotKeys()
        configureLoginItemOnFirstLaunch()
        ensureSaveFolder()
        capturer.refresh()
        handleTerminationSignal()
        launched = true
        let opens = pendingOpens
        pendingOpens = []
        if !opens.isEmpty { open(opens) }
    }

    // MARK: Quitting

    /// `restart.sh` and `uninstall.sh` stop the app with SIGTERM; route it through the normal quit so editors are saved.
    private func handleTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            Log.info("Received SIGTERM; quitting")
            NSApp.terminate(nil)
        }
        source.resume()
        terminationSignal = source
    }

    /// AppKit doesn't ask windows before quitting, so commit every editor with unsaved changes here, synchronously.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        var lastCopy: (data: Data, url: URL?)?
        for editor in editors {
            guard let result = editor.commitNow() else { continue }
            if let data = result.data { lastCopy = (data, result.saved ? editor.fileURL : nil) }
            Log.info(result.saved ? "Saved \(editor.fileURL.lastPathComponent) before quitting" : "Could not save \(editor.fileURL.lastPathComponent) before quitting")
        }
        if let lastCopy { Output.copyToClipboard(png: lastCopy.data, fileURL: lastCopy.url) }
        // Let queued capture writes land too.
        Output.io.sync {}
        Log.info("Quitting")
        return .terminateNow
    }

    // MARK: Opening files and URLs

    /// Images from `open -a "Snap It"`, the app icon or Open With, and `snapit://` URLs.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard launched else {
            pendingOpens += urls
            return
        }
        open(urls)
    }

    private func open(_ urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                openImage(url)
            } else if url.scheme?.lowercased() == "snapit" {
                handleURL(url)
            } else {
                Log.info("Ignoring \(url.absoluteString)")
            }
        }
    }

    private func handleURL(_ url: URL) {
        let command = (url.host ?? url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        switch command {
        case "capture-area": captureArea(trigger: "url")
        case "capture-fullscreen": captureFullScreen(trigger: "url")
        default: Log.info("Unknown URL \(url.absoluteString); expected snapit://capture-area or snapit://capture-fullscreen")
        }
    }

    private func openImage(_ url: URL) {
        let start = CACurrentMediaTime()
        guard let (image, scale) = OpenedImage.load(url) else {
            Log.info("Could not open \(url.path) as an image")
            NSSound.beep()
            return
        }
        rememberFrontmostApp()
        let saveURL = OpenedImage.saveURL(for: url)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let editor = EditorWindowController(image: image, scale: scale, fileURL: saveURL, sourceURL: url, screen: screen, settings: settings)
        showEditor(editor)
        Log.info("Opened \(url.lastPathComponent) (\(image.width)×\(image.height) px @\(String(format: "%g", scale))x, saves to \(saveURL.lastPathComponent)) in \(Log.ms(since: start))")
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = symbol("camera.viewfinder", "camera", description: "Snap It")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Snap It"
        let menu = NSMenu()
        menu.delegate = self
        let area = NSMenuItem(title: "Capture Area", action: #selector(captureAreaFromMenu), keyEquivalent: "4")
        area.keyEquivalentModifierMask = [.command, .shift]
        let full = NSMenuItem(title: "Capture Full Screen", action: #selector(captureFullScreenFromMenu), keyEquivalent: "3")
        full.keyEquivalentModifierMask = [.command, .shift]
        let folder = NSMenuItem(title: "Open Screenshots Folder", action: #selector(openFolder), keyEquivalent: "")
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit Snap It", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for menuItem in [area, full, folder, login] { menuItem.target = self }
        menu.items = [area, full, .separator(), folder, login, .separator(), quit]
        item.menu = menu
        loginMenuItem = login
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginMenuItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func captureAreaFromMenu() {
        // Let the menu close first so it isn't in the frozen frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.captureArea(trigger: "menu") }
    }

    @objc private func captureFullScreenFromMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.captureFullScreen(trigger: "menu") }
    }

    @objc private func openFolder() {
        ensureSaveFolder()
        NSWorkspace.shared.open(settings.saveFolder)
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                Log.info("Open at Login turned off")
            } else {
                try service.register()
                Log.info("Open at Login turned on")
            }
        } catch {
            Log.info("Open at Login change failed: \(error.localizedDescription)")
        }
        UserDefaults.standard.set(true, forKey: "loginItemConfigured")
    }

    private func configureLoginItemOnFirstLaunch() {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            Log.info("Not running from an app bundle; leaving Open at Login alone")
            return
        }
        guard !UserDefaults.standard.bool(forKey: "loginItemConfigured") else { return }
        do {
            try SMAppService.mainApp.register()
            Log.info("Registered Open at Login (first launch)")
        } catch {
            Log.info("Could not register Open at Login: \(error.localizedDescription)")
        }
        UserDefaults.standard.set(true, forKey: "loginItemConfigured")
    }

    private func ensureSaveFolder() {
        do {
            try FileManager.default.createDirectory(at: settings.saveFolder, withIntermediateDirectories: true)
        } catch {
            Log.info("Could not create \(settings.saveFolder.path): \(error.localizedDescription)")
        }
    }

    // MARK: Hotkeys

    private func registerHotKeys() {
        let mods = cmdKey | shiftKey
        let center = HotKeyCenter.shared
        center.register(id: 4, keyCode: kVK_ANSI_4, modifiers: mods, name: "⌘⇧4 (capture area)") { [weak self] in self?.captureArea(trigger: "⌘⇧4") }
        center.register(id: 3, keyCode: kVK_ANSI_3, modifiers: mods, name: "⌘⇧3 (capture full screen)") { [weak self] in self?.captureFullScreen(trigger: "⌘⇧3") }
        center.register(id: 5, keyCode: kVK_ANSI_5, modifiers: mods, name: "⌘⇧5 (capture area)") { [weak self] in self?.captureArea(trigger: "⌘⇧5") }
    }

    // MARK: Capture

    private func captureArea(trigger: String) {
        guard !capturing else { return }
        capturing = true
        let start = CACurrentMediaTime()
        rememberFrontmostApp()
        Task {
            do {
                let captures = try await capturer.captureAllDisplays()
                let captured = Log.ms(since: start)
                let overlay = OverlayController(captures: captures) { selection in
                    self.overlayFinished(selection, mouseUp: CACurrentMediaTime())
                }
                self.overlay = overlay
                overlay.show()
                let shown = Log.ms(since: start)
                DispatchQueue.main.async {
                    let sizes = captures.map { "\($0.image.width)×\($0.image.height)@\(String(format: "%g", $0.scale))x" }.joined(separator: ", ")
                    Log.info("Area capture (\(trigger)): \(captures.count) displays [\(sizes)] captured in \(captured), overlays ordered front in \(shown), visible after \(Log.ms(since: start))")
                }
            } catch {
                capturing = false
                handleCaptureError(error)
            }
        }
    }

    private func overlayFinished(_ selection: OverlayController.Selection?, mouseUp: CFTimeInterval) {
        overlay = nil
        capturing = false
        guard let selection else {
            Log.info("Area capture cancelled")
            handBackFocus()
            return
        }
        afterCapture(image: selection.image, scale: selection.capture.scale, screen: selection.capture.screen, start: mouseUp, label: "mouse-up")
    }

    private func captureFullScreen(trigger: String) {
        guard !capturing else { return }
        capturing = true
        let start = CACurrentMediaTime()
        rememberFrontmostApp()
        Task {
            defer { capturing = false }
            do {
                let capture = try await capturer.captureDisplay(containing: NSEvent.mouseLocation)
                Log.info("Full screen capture (\(trigger)): \(capture.image.width)×\(capture.image.height) in \(Log.ms(since: start))")
                afterCapture(image: capture.image, scale: capture.scale, screen: capture.screen, start: start, label: "hotkey")
            } catch {
                handleCaptureError(error)
            }
        }
    }

    /// Sound, save, clipboard, then the editor straight away. Saving runs in the background.
    private func afterCapture(image: CGImage, scale: CGFloat, screen: NSScreen, start: CFTimeInterval, label: String) {
        Output.playShutter()
        ensureSaveFolder()
        let url = ScreenshotNaming.uniqueURL(in: settings.saveFolder, date: Date(), scale: scale) { [reservedPaths] in
            reservedPaths.contains($0.path) || FileManager.default.fileExists(atPath: $0.path)
        }
        reservedPaths.insert(url.path)
        Output.write(image, scale: scale, to: url) { [weak self] result in
            guard let self else { return }
            reservedPaths.remove(url.path)
            guard result.saved, let data = result.data else {
                // The editor keeps the capture as unsaved, so closing it tries again.
                if let editor = editors.first(where: { $0.fileURL == url }) {
                    editor.saveFailed(data: result.data)
                } else if let data = result.data {
                    Output.copyToClipboard(png: data, fileURL: nil)
                }
                return
            }
            Output.copyToClipboard(png: data, fileURL: url)
            Log.info("Saved and copied \(url.lastPathComponent) (\(data.count / 1024) KB) \(Log.ms(since: start)) after \(label)")
        }
        showEditor(EditorWindowController(image: image, scale: scale, fileURL: url, screen: screen, settings: settings))
        DispatchQueue.main.async {
            Log.info("Editor visible \(Log.ms(since: start)) after \(label) (\(image.width)×\(image.height) px)")
        }
    }

    private func showEditor(_ editor: EditorWindowController) {
        editor.onClose = { [weak self] closed in
            guard let self else { return }
            editors.removeAll { $0 === closed }
            if editors.isEmpty { handBackFocus() }
        }
        editors.append(editor)
        editor.present()
    }

    private func rememberFrontmostApp() {
        if let app = NSWorkspace.shared.frontmostApplication, app != NSRunningApplication.current { previousApp = app }
    }

    /// With nothing of ours left on screen, give focus back to the app you were in.
    private func handBackFocus() {
        guard overlay == nil, editors.isEmpty else { return }
        if let previousApp, !previousApp.isTerminated, previousApp != NSRunningApplication.current {
            previousApp.activate()
        } else {
            NSApp.hide(nil)
        }
    }

    private func handleCaptureError(_ error: Error) {
        Log.info("Capture failed: \(error)")
        guard ScreenCapturer.isPermissionError(error) else { return }
        showPermissionAlert()
    }

    /// One alert at a time, and not again within a minute.
    private func showPermissionAlert() {
        if let shown = permissionAlertShown, Date().timeIntervalSince(shown) < 60 { return }
        permissionAlertShown = Date()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Snap It needs Screen Recording permission"
        alert.informativeText = "Turn on Snap It in System Settings > Privacy & Security > Screen & System Audio Recording, then try again. macOS may ask you to quit and reopen it."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Hidden for a menu bar app, but it gives editor windows their standard key equivalents.
enum MainMenu {
    @MainActor
    static func build() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Snap It")
        appMenu.addItem(withTitle: "Quit Snap It", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Save", action: #selector(EditorWindowController.editorSave(_:)), keyEquivalent: "s")
        let done = file.addItem(withTitle: "Done", action: #selector(EditorWindowController.editorDone(_:)), keyEquivalent: "\r")
        done.keyEquivalentModifierMask = [.command]
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: #selector(EditorWindowController.editorUndo(_:)), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: #selector(EditorWindowController.editorRedo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
