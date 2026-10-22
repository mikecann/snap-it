import AppKit
import ScreenCaptureKit
import SnapItCore

/// One display frozen at the moment of capture.
struct DisplayCapture {
    let screen: NSScreen
    let image: CGImage
    let mapping: DisplayMapping
    var scale: CGFloat { mapping.scale }
}

enum CaptureError: Error {
    case permissionDenied
    case noDisplay
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
}

/// Captures whole displays once each with ScreenCaptureKit. Never asks for per-window images:
/// the overlay crops from these frozen frames.
@MainActor
final class ScreenCapturer {
    private var cached: SCShareableContent?
    private var refreshing: Task<SCShareableContent, Error>?
    private var refreshAgain = false

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.info("Screen parameters changed; refreshing the display list")
                self?.cached = nil
                self?.refresh()
            }
        }
    }

    /// Fetches the display and window list in the background so the next hotkey press doesn't wait for it.
    /// Only Finder's desktop-icon windows are excluded from captures, and those rarely change, so a slightly stale list is fine.
    func refresh() {
        guard CGPreflightScreenCaptureAccess() else { return }
        guard refreshing == nil else {
            refreshAgain = true
            return
        }
        let task = Task { try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        refreshing = task
        Task {
            let result = try? await task.value
            if let result { self.cached = result }
            self.refreshing = nil
            if self.refreshAgain {
                self.refreshAgain = false
                self.refresh()
            }
        }
    }

    private func content() async throws -> SCShareableContent {
        if let cached { return cached }
        if let refreshing { return try await refreshing.value }
        let start = CACurrentMediaTime()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        Log.info("Fetched shareable content in \(Log.ms(since: start))")
        cached = content
        return content
    }

    /// Finder's desktop-icon windows. Everything else stays, including open editors, so the frozen frame
    /// matches what's on screen. The overlay doesn't exist yet when the displays are captured.
    private func excludedWindows(in content: SCShareableContent) -> [SCWindow] {
        content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == "com.apple.finder" && window.windowLayer < 0
        }
    }

    func captureAllDisplays() async throws -> [DisplayCapture] {
        let content = try await content()
        let excluded = excludedWindows(in: content)
        let screens = NSScreen.screens
        let pairs: [(SCDisplay, NSScreen)] = content.displays.compactMap { display in
            screens.first { $0.displayID == display.displayID }.map { (display, $0) }
        }
        guard !pairs.isEmpty else { throw CaptureError.noDisplay }
        defer { refresh() }
        return try await withThrowingTaskGroup(of: (Int, DisplayCapture).self) { group in
            for (index, pair) in pairs.enumerated() {
                let filter = SCContentFilter(display: pair.0, excludingWindows: excluded)
                let config = Self.configuration(for: filter, screen: pair.1)
                let screen = pair.1
                group.addTask {
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    return (index, await Self.makeCapture(image: image, screen: screen))
                }
            }
            var results: [(Int, DisplayCapture)] = []
            for try await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    func captureDisplay(containing point: CGPoint) async throws -> DisplayCapture {
        let content = try await content()
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main,
              let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { throw CaptureError.noDisplay }
        defer { refresh() }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows(in: content))
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: Self.configuration(for: filter, screen: screen))
        return Self.makeCapture(image: image, screen: screen)
    }

    private nonisolated static func configuration(for filter: SCContentFilter, screen: NSScreen) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        return config
    }

    @MainActor
    private static func makeCapture(image: CGImage, screen: NSScreen) -> DisplayCapture {
        DisplayCapture(screen: screen, image: image,
                       mapping: DisplayMapping(frame: screen.frame, pixelSize: CGSize(width: image.width, height: image.height)))
    }

    static func isPermissionError(_ error: Error) -> Bool {
        if case CaptureError.permissionDenied = error { return true }
        let ns = error as NSError
        if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.userDeclined.rawValue { return true }
        // Without the grant, ScreenCaptureKit can fail with other codes; preflight tells us the real reason.
        return !CGPreflightScreenCaptureAccess()
    }
}
