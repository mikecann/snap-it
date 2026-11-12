import AppKit
import AVFoundation
import SnapItCore

/// A finished recording, with times in the video.
struct FinishedRecording {
    let folder: URL
    let videoURL: URL
    let duration: TimeInterval
    let videoSize: CGSize
    /// The recorded area in points.
    let pointSize: CGSize
    let timeline: InputTimeline
    let clicksRecorded: Bool
    let keysRecorded: Bool
    let screen: NSScreen

    var summaryURL: URL { RecordingNaming.summaryURL(inFolder: folder) }
}

/// One screen recording: the recorder, the click and key overlay, a red outline around the area and a
/// small Stop panel beside it. The outline and the panel are left out of the video.
@MainActor
final class RecordingSession {
    let folder: URL
    let videoURL: URL
    private let screen: NSScreen
    private let pointSize: CGSize
    private let recorder: ScreenRecorder
    private let visualizer: InputVisualizer
    private let chrome: RecordingChrome
    private let startedAt = CACurrentMediaTime()
    private var ticker: Timer?
    /// Called about twice a second with the time so far.
    var onTick: ((TimeInterval) -> Void)?

    private init(folder: URL, screen: NSScreen, pointSize: CGSize, recorder: ScreenRecorder, visualizer: InputVisualizer, chrome: RecordingChrome) {
        self.folder = folder
        videoURL = recorder.url
        self.screen = screen
        self.pointSize = pointSize
        self.recorder = recorder
        self.visualizer = visualizer
        self.chrome = chrome
    }

    /// Puts up the outline, the panel and the overlay, then starts recording `localRect` (display points, top-left origin).
    static func start(capture: DisplayCapture, localRect: CGRect, folder: URL, settings: SnapItSettings,
                      capturer: ScreenCapturer, onStop: @escaping () -> Void) async throws -> RecordingSession {
        let mapping = capture.mapping
        let topLeft = mapping.globalPoint(fromLocal: localRect.origin)
        let region = CGRect(x: topLeft.x, y: topLeft.y - localRect.height, width: localRect.width, height: localRect.height)
        let pixelSize = mapping.pixelRect(fromLocal: localRect).size
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let chrome = RecordingChrome(region: region, screen: capture.screen, onStop: onStop)
        let visualizer = InputVisualizer(region: region, showClicks: settings.showClicks, showKeys: settings.showKeys)
        chrome.show()
        do {
            let filter = try await capturer.recordingFilter(for: capture.screen, excludingWindowNumbers: chrome.windowNumbers)
            let recorder = try ScreenRecorder(filter: filter, sourceRect: localRect, pixelSize: pixelSize,
                                              url: RecordingNaming.videoURL(inFolder: folder))
            try await recorder.start()
            visualizer.start()
            let session = RecordingSession(folder: folder, screen: capture.screen, pointSize: localRect.size,
                                           recorder: recorder, visualizer: visualizer, chrome: chrome)
            session.startTicking()
            Log.info("Recording \(Int(localRect.width))×\(Int(localRect.height)) pt at \(Int(recorder.outputSize.width))×\(Int(recorder.outputSize.height)) px "
                     + "(clicks \(settings.showClicks ? "on" : "off"), keys \(visualizer.keysRecorded ? "on" : settings.showKeys ? "unavailable" : "off"))")
            return session
        } catch {
            chrome.close()
            _ = visualizer.stop()
            throw error
        }
    }

    private func startTicking() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let elapsed = CACurrentMediaTime() - self.startedAt
                self.chrome.update(elapsed: elapsed)
                self.onTick?(elapsed)
            }
        }
    }

    func stop() async throws -> FinishedRecording {
        ticker?.invalidate()
        ticker = nil
        chrome.close()
        let raw = visualizer.stop()
        let result = try await recorder.stop()
        // Events from up to half a second before the first frame still count: the stream takes a moment to start.
        let timeline = raw.rebased(start: result.startTime, duration: result.duration, lead: 0.5)
        Log.info(String(format: "Recorded %.1f s, %d frames, %d inputs to %@", result.duration, result.frames, timeline.entries.count, videoURL.lastPathComponent))
        return FinishedRecording(folder: folder, videoURL: videoURL, duration: result.duration, videoSize: result.size, pointSize: pointSize,
                                 timeline: timeline, clicksRecorded: visualizer.clicksRecorded, keysRecorded: visualizer.keysRecorded, screen: screen)
    }
}

/// The red outline just outside the recorded area and the Stop panel below it (or above, or inside if there's no room).
@MainActor
final class RecordingChrome {
    private let outline: NSWindow
    private let panel: NSPanel
    private let timeLabel = NSTextField(labelWithString: "0:00")

    init(region: CGRect, screen: NSScreen, onStop: @escaping () -> Void) {
        let inset: CGFloat = 3
        outline = NSWindow(contentRect: region.insetBy(dx: -inset, dy: -inset), styleMask: [.borderless], backing: .buffered, defer: false)
        let outlineView = OutlineView(frame: CGRect(origin: .zero, size: outline.frame.size))
        outline.contentView = outlineView
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 150, height: 36), styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        for window in [outline, panel] as [NSWindow] {
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
        }
        outline.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true

        let background = NSVisualEffectView(frame: panel.contentLayoutRect)
        background.material = .hudWindow
        background.state = .active
        background.blendingMode = .behindWindow
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        let dot = NSImageView(image: symbol("record.circle.fill", "circle.fill", description: "Recording") ?? NSImage())
        dot.contentTintColor = .systemRed
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timeLabel.textColor = .labelColor
        let stop = ClosureButton(title: "Stop", action: onStop)
        stop.bezelStyle = .rounded
        stop.controlSize = .small
        stop.keyEquivalent = ""
        stop.toolTip = "Stop recording (or press ⌘⇧4)"
        let stack = NSStackView(views: [dot, timeLabel, stop])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        stack.frame = background.bounds
        stack.autoresizingMask = [.width, .height]
        background.addSubview(stack)
        panel.contentView = background

        // Below the area's bottom-right corner, else above it, else just inside it.
        let visible = screen.visibleFrame
        let size = panel.frame.size
        var origin = CGPoint(x: region.maxX - size.width, y: region.minY - inset - 8 - size.height)
        if origin.y < visible.minY { origin.y = region.maxY + inset + 8 }
        if origin.y + size.height > visible.maxY { origin.y = region.minY + 12 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrameOrigin(origin)
    }

    var windowNumbers: [Int] { [outline.windowNumber, panel.windowNumber] }

    func show() {
        outline.orderFrontRegardless()
        panel.orderFrontRegardless()
    }

    func update(elapsed: TimeInterval) {
        let seconds = Int(elapsed)
        timeLabel.stringValue = String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func close() {
        outline.orderOut(nil)
        panel.orderOut(nil)
    }
}

private final class OutlineView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.setLineDash([8, 5], count: 2, phase: 0)
        NSColor.systemRed.setStroke()
        path.stroke()
    }
}

final class ClosureButton: NSButton {
    private var handler: () -> Void = {}

    convenience init(title: String, action: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        handler = action
        target = self
        self.action = #selector(fire)
    }

    @objc private func fire() { handler() }
}

/// `summary.md` and the frames beside a recording, for agents that can't watch video.
enum RecordingNotes {
    static func write(for recording: FinishedRecording) async {
        let start = CACurrentMediaTime()
        let framesFolder = RecordingNaming.framesFolder(inFolder: recording.folder)
        try? FileManager.default.removeItem(at: framesFolder)
        try? FileManager.default.createDirectory(at: framesFolder, withIntermediateDirectories: true)
        let asset = AVURLAsset(url: recording.videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Point size is plenty for reading a UI, and keeps each frame small for an agent.
        let longSide = max(recording.pointSize.width, recording.pointSize.height)
        let fit = min(1, 1600 / max(longSide, 1))
        generator.maximumSize = CGSize(width: recording.pointSize.width * fit, height: recording.pointSize.height * fit)
        var frames: [(TimeInterval, String)] = []
        for (i, time) in FramePlan.times(for: recording.timeline, duration: recording.duration).enumerated() {
            // Tenths rounded down, the same as the times in summary.md.
            let tenths = Int((time * 10).rounded(.down))
            let name = String(format: "frame-%02d-%d.%ds.png", i + 1, tenths / 10, tenths % 10)
            do {
                let (image, _) = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
                if let data = PNGWriter.data(for: image, scale: 1) {
                    try data.write(to: framesFolder.appendingPathComponent(name))
                    frames.append((time, "frames/\(name)"))
                }
            } catch {
                Log.info("Couldn't grab a frame at \(time) s: \(error.localizedDescription)")
            }
        }
        let summary = RecordingSummary(title: recording.folder.lastPathComponent, videoFileName: recording.videoURL.lastPathComponent,
                                       duration: recording.duration, videoSize: recording.videoSize, pointSize: recording.pointSize,
                                       timeline: recording.timeline, frames: frames,
                                       clicksRecorded: recording.clicksRecorded, keysRecorded: recording.keysRecorded)
        do {
            try summary.markdown.write(to: recording.summaryURL, atomically: true, encoding: .utf8)
            Log.info("Wrote summary.md and \(frames.count) frames for \(recording.folder.lastPathComponent) in \(Log.ms(since: start))")
        } catch {
            Log.info("Couldn't write \(recording.summaryURL.path): \(error.localizedDescription)")
        }
    }
}
