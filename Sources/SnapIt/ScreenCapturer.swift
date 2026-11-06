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
    /// Bumped on every screen change, so a fetch that started before the change can't put its stale list back in the cache.
    private var generation = 0

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.info("Screen parameters changed; refreshing the display list")
                self?.generation += 1
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
        let startedAt = generation
        Task {
            let result = try? await task.value
            if let result, startedAt == self.generation { self.cached = result }
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
        return try await fetch()
    }

    /// Fetches in the foreground. Only caches the result if no screen change happened while it was in
    /// flight, so it can't overwrite a newer list that a background refresh stored meanwhile.
    private func fetch() async throws -> SCShareableContent {
        let startedAt = generation
        let start = CACurrentMediaTime()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        Log.info("Fetched shareable content in \(Log.ms(since: start))")
        if startedAt == generation { cached = content }
        return content
    }

    /// The display list, checked against the screens AppKit sees right now. On 6 Nov, plugging displays
    /// in and out left a list from partway through the change in the cache, and every capture failed
    /// with noDisplay until the app was relaunched. So when the list doesn't cover every screen, fetch it
    /// fresh once before giving up.
    private func currentContent() async throws -> SCShareableContent {
        let content = try await content()
        let ids = Set(content.displays.map(\.displayID))
        if NSScreen.screens.allSatisfy({ $0.displayID.map(ids.contains) ?? false }) { return content }
        Log.info("Display list doesn't match the screens; fetching it again")
        // Retire any background refresh that started before this point, then fetch fresh.
        generation += 1
        cached = nil
        return try await fetch()
    }

    /// Finder's desktop-icon windows. Everything else stays, including open editors, so the frozen frame
    /// matches what's on screen. The overlay doesn't exist yet when the displays are captured.
    private func excludedWindows(in content: SCShareableContent) -> [SCWindow] {
        content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == "com.apple.finder" && window.windowLayer < 0
        }
    }

    func captureAllDisplays() async throws -> [DisplayCapture] {
        let content = try await currentContent()
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
        let content = try await currentContent()
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
        // Mike wants the pointer in his shots. It's baked in where it was when the hotkey fired,
        // so area captures show it frozen under the live crosshair, the same as CleanShot did.
        config.showsCursor = true
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
