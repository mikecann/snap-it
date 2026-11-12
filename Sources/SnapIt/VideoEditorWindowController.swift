import AppKit
import AVFoundation
import AVKit
import SnapItCore

/// Plays a finished recording on a loop, with QuickTime's trim handles, Copy, drag-out and Done.
/// The video, its frames and summary.md are already saved and on the clipboard when this opens.
@MainActor
final class VideoEditorWindowController: NSWindowController, NSWindowDelegate {
    private(set) var recording: FinishedRecording
    private let playerView = AVPlayerView()
    private let player = AVPlayer()
    private let toolbar = NSStackView()
    private let infoLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var buttons: [NSButton] = []
    private var endObserver: NSObjectProtocol?
    private var busy = false
    /// The trim handles are up; looping waits so the playhead stays where you're trimming.
    private var trimming = false
    var onClose: ((VideoEditorWindowController) -> Void)?

    static let toolbarHeight: CGFloat = 46

    init(recording: FinishedRecording) {
        self.recording = recording
        let visible = recording.screen.visibleFrame
        let maxSize = CGSize(width: visible.width * 0.8, height: visible.height * 0.8 - Self.toolbarHeight)
        let natural = recording.pointSize
        let fit = min(1, maxSize.width / max(natural.width, 1), maxSize.height / max(natural.height, 1))
        let contentSize = CGSize(width: max(ceil(natural.width * fit), 600), height: max(ceil(natural.height * fit), 200) + Self.toolbarHeight)
        let window = EditorWindow(contentRect: CGRect(origin: .zero, size: contentSize),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = recording.folder.lastPathComponent
        window.representedURL = recording.videoURL
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.contentMinSize = CGSize(width: 600, height: 200)
        window.backgroundColor = NSColor(white: 0.16, alpha: 1)
        super.init(window: window)
        window.delegate = self

        let container = NSView(frame: CGRect(origin: .zero, size: contentSize))
        playerView.frame = CGRect(x: 0, y: 0, width: contentSize.width, height: contentSize.height - Self.toolbarHeight)
        playerView.autoresizingMask = [.width, .height]
        playerView.controlsStyle = .inline
        playerView.showsFrameSteppingButtons = true
        playerView.showsSharingServiceButton = false
        playerView.player = player
        let bar = NSView(frame: CGRect(x: 0, y: contentSize.height - Self.toolbarHeight, width: contentSize.width, height: Self.toolbarHeight))
        bar.autoresizingMask = [.width, .minYMargin]
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        buildToolbar(in: bar)
        container.addSubview(playerView)
        container.addSubview(bar)
        window.contentView = container
        window.setFrameOrigin(CGPoint(x: max(visible.midX - contentSize.width / 2, visible.minX),
                                      y: max(visible.midY - contentSize.height / 2, visible.minY)))
        load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func buildToolbar(in bar: NSView) {
        func button(_ title: String, _ symbolName: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, image: symbol(symbolName, description: title) ?? NSImage(), target: self, action: action)
            b.imagePosition = .imageLeading
            b.bezelStyle = .texturedRounded
            b.toolTip = tip
            buttons.append(b)
            return b
        }
        let trim = button("Trim", "timeline.selection", "Trim the start and end (⌘T)", #selector(trimVideo(_:)))
        let finder = button("Show in Finder", "folder", "Show the video, its frames and summary.md in Finder", #selector(showInFinder(_:)))
        // Icon only, so the bar fits a small recording's window.
        finder.title = ""
        finder.imagePosition = .imageOnly
        let copy = button("Copy", "doc.on.doc", "Copy the video and where its summary is (⌘C)", #selector(copyRecording(_:)))
        let done = button("Done", "checkmark", "Copy and close (Return)", #selector(editorDone(_:)))
        done.keyEquivalent = "\r"
        trim.keyEquivalent = "t"
        trim.keyEquivalentModifierMask = [.command]
        let dragOut = DragOutView(frame: CGRect(x: 0, y: 0, width: 30, height: 28))
        dragOut.toolTip = "Drag the video into another app"
        dragOut.widthAnchor.constraint(equalToConstant: 30).isActive = true
        dragOut.heightAnchor.constraint(equalToConstant: 28).isActive = true
        dragOut.provider = { [weak self] in
            guard let self, !busy else { return nil }
            return (recording.videoURL, NSWorkspace.shared.icon(forFile: recording.videoURL.path))
        }
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        toolbar.setViews([trim, finder, infoLabel, spacer, spinner, dragOut, copy, done], in: .leading)
        toolbar.spacing = 8
        toolbar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        toolbar.frame = bar.bounds
        toolbar.autoresizingMask = [.width, .height]
        bar.addSubview(toolbar)
    }

    /// (Re)loads the video, which loops until the window closes.
    private func load() {
        let item = AVPlayerItem(asset: AVURLAsset(url: recording.videoURL))
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.trimming else { return }
                self.player.seek(to: .zero)
                self.player.play()
            }
        }
        player.replaceCurrentItem(with: item)
        player.isMuted = true
        player.play()
        let size = "\(Int(recording.videoSize.width)) × \(Int(recording.videoSize.height))"
        infoLabel.stringValue = String(format: "%.1f s, %@", recording.duration, size)
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(playerView)
    }

    private func setBusy(_ value: Bool) {
        busy = value
        for button in buttons { button.isEnabled = !value }
        if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    // MARK: Commands

    @objc func copyRecording(_ sender: Any?) {
        guard !busy else { return }
        Output.copyRecording(recording)
    }

    /// ⌘C from the Edit menu.
    @objc func copy(_ sender: Any?) { copyRecording(sender) }

    /// Escape closes, unless the trim handles are up: the player view takes Escape for those first.
    override func cancelOperation(_ sender: Any?) { window?.performClose(nil) }

    @objc func editorDone(_ sender: Any?) {
        guard !busy else { return }
        Output.copyRecording(recording)
        window?.close()
    }

    @objc func showInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.videoURL])
    }

    @objc func trimVideo(_ sender: Any?) {
        guard !busy, playerView.canBeginTrimming else { return }
        player.pause()
        trimming = true
        playerView.beginTrimming { [weak self] result in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.trimming = false
                let duration = self.recording.duration
                guard result == .okButton, let item = self.player.currentItem else {
                    self.player.play()
                    return
                }
                let start = item.reversePlaybackEndTime.isNumeric ? item.reversePlaybackEndTime.seconds : 0
                let end = item.forwardPlaybackEndTime.isNumeric ? item.forwardPlaybackEndTime.seconds : duration
                guard end - start > 0.05, start > 0.01 || end < duration - 0.01 else {
                    self.player.play()
                    return
                }
                self.applyTrim(start: start, end: end)
            }
        }
    }

    /// Re-encodes the kept part over the original, then redoes the frames and summary to match.
    private func applyTrim(start: TimeInterval, end: TimeInterval) {
        setBusy(true)
        let began = CACurrentMediaTime()
        let original = recording
        let temp = original.folder.appendingPathComponent(".trimming.mp4")
        try? FileManager.default.removeItem(at: temp)
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: original.videoURL), presetName: AVAssetExportPresetHighestQuality) else {
            trimFailed("couldn't create an export session")
            return
        }
        export.outputURL = temp
        export.outputFileType = .mp4
        export.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        // Let go of the file while it's replaced.
        player.replaceCurrentItem(with: nil)
        export.exportAsynchronously { [weak self] in
            let status = export.status
            let message = export.error?.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard status == .completed else {
                        self.trimFailed(message ?? "export \(status.rawValue)")
                        return
                    }
                    do {
                        _ = try FileManager.default.replaceItemAt(original.videoURL, withItemAt: temp)
                    } catch {
                        self.trimFailed(error.localizedDescription)
                        return
                    }
                    let duration = end - start
                    self.recording = FinishedRecording(folder: original.folder, videoURL: original.videoURL, duration: duration,
                                                       videoSize: original.videoSize, pointSize: original.pointSize,
                                                       timeline: original.timeline.rebased(start: start, duration: duration),
                                                       clicksRecorded: original.clicksRecorded, keysRecorded: original.keysRecorded,
                                                       screen: original.screen)
                    self.load()
                    Log.info(String(format: "Trimmed %@ to %.1f to %.1f s in %@", original.videoURL.lastPathComponent, start, end, Log.ms(since: began)))
                    let trimmed = self.recording
                    Task {
                        await RecordingNotes.write(for: trimmed)
                        Output.copyRecording(trimmed)
                        self.setBusy(false)
                    }
                }
            }
        }
    }

    private func trimFailed(_ reason: String) {
        Log.info("Trim failed: \(reason)")
        setBusy(false)
        load()
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't trim the recording"
        alert.informativeText = "The original is untouched. (\(reason))"
        alert.beginSheetModal(for: window)
    }

    // MARK: NSWindowDelegate

    /// A trim in progress finishes first, so the file is never left half-written.
    func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        onClose?(self)
    }
}
