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
    private var videoEditors: [VideoEditorWindowController] = []
    private var statusMenu: NSMenu?
    private var clicksMenuItem: NSMenuItem?
    private var keysMenuItem: NSMenuItem?
    /// The recording in progress. While it runs, every Snap It hotkey and the menu bar icon stop it.
    private var recording: RecordingSession?
    /// Between letting go of the crosshair and the recording starting, and between stopping and the editor opening.
    private var recordingBusy = false
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
        // Finish the video first, so quitting mid-recording still leaves a file that plays.
        if let session = recording {
            recording = nil
            Task {
                _ = try? await session.stop()
                Log.info("Finished the recording before quitting")
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            commitEditors()
            return .terminateLater
        }
        commitEditors()
        Log.info("Quitting")
        return .terminateNow
    }

    private func commitEditors() {
        var lastCopy: (data: Data, url: URL?)?
        for editor in editors {
            guard let result = editor.commitNow() else { continue }
            if let data = result.data { lastCopy = (data, result.saved ? editor.fileURL : nil) }
            Log.info(result.saved ? "Saved \(editor.fileURL.lastPathComponent) before quitting" : "Could not save \(editor.fileURL.lastPathComponent) before quitting")
        }
        if let lastCopy { Output.copyToClipboard(png: lastCopy.data, fileURL: lastCopy.url) }
        // Let queued capture writes land too.
        Output.io.sync {}
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
        case "record-area": captureArea(trigger: "url", mode: .record)
        case "stop-recording": stopRecording(trigger: "url")
        default: Log.info("Unknown URL \(url.absoluteString); expected snapit://capture-area, capture-fullscreen, record-area or stop-recording")
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
        let record = NSMenuItem(title: "Record Area (⌘⇧4 twice)", action: #selector(recordAreaFromMenu), keyEquivalent: "")
        let clicks = NSMenuItem(title: "Show Clicks in Recordings", action: #selector(toggleShowClicks), keyEquivalent: "")
        let keys = NSMenuItem(title: "Show Keys in Recordings", action: #selector(toggleShowKeys), keyEquivalent: "")
        let folder = NSMenuItem(title: "Open Screenshots Folder", action: #selector(openFolder), keyEquivalent: "")
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit Snap It", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for menuItem in [area, full, record, clicks, keys, folder, login] { menuItem.target = self }
        menu.items = [area, full, .separator(), record, clicks, keys, .separator(), folder, login, .separator(), quit]
        item.menu = menu
        statusMenu = menu
        loginMenuItem = login
        clicksMenuItem = clicks
        keysMenuItem = keys
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginMenuItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        clicksMenuItem?.state = settings.showClicks ? .on : .off
        keysMenuItem?.state = settings.showKeys ? .on : .off
        keysMenuItem?.title = settings.showKeys && !CGPreflightListenEventAccess()
            ? "Show Keys in Recordings (needs Input Monitoring)" : "Show Keys in Recordings"
    }

    @objc private func recordAreaFromMenu() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.captureArea(trigger: "menu", mode: .record) }
    }

    @objc private func toggleShowClicks() {
        settings.showClicks.toggle()
        Log.info("Show clicks in recordings: \(settings.showClicks ? "on" : "off")")
    }

    /// Turning keys on, or picking it while it still needs permission, asks for Input Monitoring.
    @objc private func toggleShowKeys() {
        if settings.showKeys, !CGPreflightListenEventAccess() {
            if !CGRequestListenEventAccess(),
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        settings.showKeys.toggle()
        if settings.showKeys, !CGPreflightListenEventAccess() { CGRequestListenEventAccess() }
        Log.info("Show keys in recordings: \(settings.showKeys ? "on" : "off")")
    }

    /// While recording, the menu bar icon is a stop button with the time beside it.
    private func showRecordingStatus(_ on: Bool) {
        guard let item = statusItem, let button = item.button else { return }
        if on {
            item.menu = nil
            item.length = NSStatusItem.variableLength
            button.image = symbol("stop.circle.fill", "stop.fill", description: "Stop recording")
            button.image?.isTemplate = false
            button.contentTintColor = .systemRed
            button.imagePosition = .imageLeading
            button.title = " 0:00"
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.toolTip = "Stop recording (⌘⇧4)"
            button.target = self
            button.action = #selector(stopFromStatusItem)
        } else {
            item.length = NSStatusItem.squareLength
            button.title = ""
            button.contentTintColor = nil
            button.image = symbol("camera.viewfinder", "camera", description: "Snap It")
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.toolTip = "Snap It"
            button.action = nil
            item.menu = statusMenu
        }
    }

    @objc private func stopFromStatusItem() { stopRecording(trigger: "menu bar") }

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

    /// The hotkey again while the crosshair is up switches between screenshot and recording, and while recording it stops.
    private func captureArea(trigger: String, mode: CaptureMode = .screenshot) {
        if recording != nil {
            stopRecording(trigger: trigger)
            return
        }
        if let overlay {
            overlay.toggleMode()
            return
        }
        guard !capturing, !recordingBusy else { return }
        capturing = true
        let start = CACurrentMediaTime()
        rememberFrontmostApp()
        Task {
            do {
                let captures = try await capturer.captureAllDisplays()
                let captured = Log.ms(since: start)
                let overlay = OverlayController(captures: captures, mode: mode) { selection in
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
        if selection.mode == .record {
            startRecording(selection)
            return
        }
        afterCapture(image: selection.image, scale: selection.capture.scale, screen: selection.capture.screen, start: mouseUp, label: "mouse-up")
    }

    private func captureFullScreen(trigger: String) {
        if recording != nil {
            stopRecording(trigger: trigger)
            return
        }
        guard !capturing, !recordingBusy else { return }
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

    // MARK: Recording

    private func startRecording(_ selection: OverlayController.Selection) {
        recordingBusy = true
        // Give the keyboard back to the app being recorded straight away.
        if let previousApp, !previousApp.isTerminated { previousApp.activate() }
        ensureSaveFolder()
        let folder = RecordingNaming.uniqueFolder(in: settings.saveFolder, date: Date())
        let start = CACurrentMediaTime()
        Task {
            do {
                let session = try await RecordingSession.start(capture: selection.capture, localRect: selection.localRect, folder: folder,
                                                               settings: settings, capturer: capturer) { [weak self] in
                    self?.stopRecording(trigger: "Stop button")
                }
                session.onTick = { [weak self] elapsed in
                    let seconds = Int(elapsed)
                    self?.statusItem?.button?.title = String(format: " %d:%02d", seconds / 60, seconds % 60)
                }
                recording = session
                recordingBusy = false
                showRecordingStatus(true)
                Log.info("Recording started \(Log.ms(since: start)) after mouse-up")
            } catch {
                recordingBusy = false
                try? FileManager.default.removeItem(at: folder)
                NSSound.beep()
                handleCaptureError(error)
            }
        }
    }

    private func stopRecording(trigger: String) {
        guard let session = recording else { return }
        recording = nil
        recordingBusy = true
        showRecordingStatus(false)
        let start = CACurrentMediaTime()
        Log.info("Stopping the recording (\(trigger))")
        rememberFrontmostApp()
        Task {
            defer { recordingBusy = false }
            do {
                let finished = try await session.stop()
                Output.copyRecording(finished)
                showVideoEditor(VideoEditorWindowController(recording: finished))
                Log.info("Video editor visible \(Log.ms(since: start)) after stopping")
                await RecordingNotes.write(for: finished)
            } catch {
                Log.info("Recording failed: \(error)")
                NSSound.beep()
            }
        }
    }

    private func showVideoEditor(_ editor: VideoEditorWindowController) {
        editor.onClose = { [weak self] closed in
            guard let self else { return }
            videoEditors.removeAll { $0 === closed }
            if editors.isEmpty, videoEditors.isEmpty { handBackFocus() }
        }
        videoEditors.append(editor)
        editor.present()
    }

    private func showEditor(_ editor: EditorWindowController) {
        editor.onClose = { [weak self] closed in
            guard let self else { return }
            editors.removeAll { $0 === closed }
            if editors.isEmpty, videoEditors.isEmpty { handBackFocus() }
        }
        editors.append(editor)
        editor.present()
    }

    private func rememberFrontmostApp() {
        if let app = NSWorkspace.shared.frontmostApplication, app != NSRunningApplication.current { previousApp = app }
    }

    /// With nothing of ours left on screen, give focus back to the app you were in.
    private func handBackFocus() {
        guard overlay == nil, editors.isEmpty, videoEditors.isEmpty else { return }
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
