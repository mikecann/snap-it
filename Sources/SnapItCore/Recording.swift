import CoreGraphics
import Foundation

/// What the crosshair does when you let go: take a screenshot or start a screen recording.
/// Pressing the hotkey again while the crosshair is up, or clicking the switch at the top, flips it.
public enum CaptureMode: String, Sendable {
    case screenshot, record

    public var toggled: CaptureMode { self == .screenshot ? .record : .screenshot }
}

/// Each recording gets its own folder, so the video and the notes for agents (frames and a timeline) stay together:
/// `Screen Recording 2026-11-12 at 11.06.29 AM/Screen Recording 2026-11-12 at 11.06.29 AM.mp4`.
public enum RecordingNaming {
    public static func folderName(date: Date, copy: Int = 1, timeZone: TimeZone = .current) -> String {
        let stamp = ScreenshotNaming.baseName(for: date, timeZone: timeZone).dropFirst("Screenshot ".count)
        return "Screen Recording \(stamp)\(copy > 1 ? " (\(copy))" : "")"
    }

    public static func uniqueFolder(in folder: URL, date: Date, timeZone: TimeZone = .current,
                                    exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        var copy = 1
        while true {
            let url = folder.appendingPathComponent(folderName(date: date, copy: copy, timeZone: timeZone), isDirectory: true)
            if !exists(url) { return url }
            copy += 1
        }
    }

    public static func videoURL(inFolder folder: URL) -> URL {
        folder.appendingPathComponent(folder.lastPathComponent).appendingPathExtension("mp4")
    }

    public static func summaryURL(inFolder folder: URL) -> URL { folder.appendingPathComponent("summary.md") }
    public static func framesFolder(inFolder folder: URL) -> URL { folder.appendingPathComponent("frames", isDirectory: true) }
}

public enum VideoGeometry {
    /// The encoder's frame size for an area of `pixelSize`: even sides (H.264 needs them), and no bigger than
    /// 4K either way round, which is about the limit of the hardware H.264 encoder. A whole 5K display scales down.
    public static func outputSize(for pixelSize: CGSize) -> CGSize {
        let long: CGFloat = 3840, short: CGFloat = 2160
        let landscape = pixelSize.width >= pixelSize.height
        let maxW = landscape ? long : short, maxH = landscape ? short : long
        let fit = min(1, maxW / max(pixelSize.width, 1), maxH / max(pixelSize.height, 1))
        func even(_ v: CGFloat) -> CGFloat { max(2, (v * fit / 2).rounded(.down) * 2) }
        return CGSize(width: even(pixelSize.width), height: even(pixelSize.height))
    }
}

// MARK: Keys

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let control = KeyModifiers(rawValue: 1)
    public static let option = KeyModifiers(rawValue: 2)
    public static let shift = KeyModifiers(rawValue: 4)
    public static let command = KeyModifiers(rawValue: 8)

    /// Apple's order: ⌃⌥⇧⌘.
    public var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

/// A key press as it should appear: typed text that runs together ("hello"), or a named key or shortcut ("⌘K", "Return").
public enum KeyPress: Equatable, Sendable {
    case text(String)
    case shortcut(String)
}

public enum KeyNames {
    /// Keys whose names beat whatever character they produce.
    static let special: [UInt16: String] = [
        36: "Return", 76: "Enter", 48: "Tab", 49: "Space", 51: "⌫", 117: "⌦", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// `typed` is what the key produced with its modifiers, `baseKey` what it produces with none (from the keyboard layout).
    public static func press(keyCode: UInt16, modifiers: KeyModifiers, typed: String, baseKey: String) -> KeyPress? {
        let chord = modifiers.intersection([.command, .control, .option])
        if chord.isEmpty {
            if keyCode == 49 { return .text(" ") }
            if let name = special[keyCode] { return .shortcut(modifiers.symbols + name) }
            let printable = typed.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            return !typed.isEmpty && printable ? .text(typed) : nil
        }
        let key = special[keyCode] ?? baseKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return key.isEmpty ? nil : .shortcut(modifiers.symbols + key)
    }

    /// ⌘⇧3, ⌘⇧4 and ⌘⇧5 are Snap It's own hotkeys. Pressing one stops a recording, so it's left out of it.
    public static func isSnapItHotkey(keyCode: UInt16, modifiers: KeyModifiers) -> Bool {
        modifiers == [.command, .shift] && [20, 21, 23].contains(keyCode)
    }
}

// MARK: Timeline

public enum MouseButton: String, Sendable {
    case left, right, other
}

public struct InputEntry: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case typed(String)
        case shortcut(String, count: Int)
        case click(MouseButton, at: CGPoint, count: Int)
        case drag(MouseButton, from: CGPoint, to: CGPoint)
    }

    /// When it started and when it last changed, in seconds.
    public var time: TimeInterval
    public var lastTime: TimeInterval
    public var kind: Kind

    var isKey: Bool {
        switch kind {
        case .typed, .shortcut: true
        case .click, .drag: false
        }
    }
}

/// What you clicked and typed during a recording. Points are in the recorded area, top-left origin.
/// While recording, times are the host clock; `rebased` turns them into times in the video.
public struct InputTimeline: Sendable {
    public private(set) var entries: [InputEntry] = []
    private var pressed: (button: MouseButton, point: CGPoint, time: TimeInterval, count: Int)?

    /// Typing that pauses for longer than this starts a new entry.
    static let typingPause: TimeInterval = 1.5
    /// The same shortcut again within this counts up ("⌫ ×3") instead of adding an entry.
    static let repeatWindow: TimeInterval = 1.0
    /// A press that moves further than this, in points, is a drag.
    static let dragDistance: CGFloat = 4

    public init() {}

    public mutating func key(_ press: KeyPress, at time: TimeInterval) {
        let last = entries.indices.last
        switch press {
        case .text(let text):
            if let last, case .typed(let previous) = entries[last].kind, time - entries[last].lastTime <= Self.typingPause {
                entries[last].kind = .typed(previous + text)
                entries[last].lastTime = time
                return
            }
            entries.append(InputEntry(time: time, lastTime: time, kind: .typed(text)))
        case .shortcut(let label):
            if let last, case .shortcut(let previous, let count) = entries[last].kind, previous == label,
               time - entries[last].lastTime <= Self.repeatWindow {
                entries[last].kind = .shortcut(label, count: count + 1)
                entries[last].lastTime = time
                return
            }
            entries.append(InputEntry(time: time, lastTime: time, kind: .shortcut(label, count: 1)))
        }
    }

    public mutating func mouseDown(_ button: MouseButton, at point: CGPoint, time: TimeInterval, clickCount: Int) {
        flushPressed(upAt: point, time: time)
        pressed = (button, point, time, max(clickCount, 1))
    }

    public mutating func mouseUp(_ button: MouseButton, at point: CGPoint, time: TimeInterval) {
        guard let down = pressed, down.button == button else { return }
        flushPressed(upAt: point, time: time)
    }

    /// A button still held when the recording stops counts as a click where it went down.
    public mutating func finish() {
        guard let down = pressed else { return }
        flushPressed(upAt: down.point, time: down.time)
    }

    private mutating func flushPressed(upAt point: CGPoint, time: TimeInterval) {
        guard let down = pressed else { return }
        pressed = nil
        if hypot(point.x - down.point.x, point.y - down.point.y) > Self.dragDistance {
            entries.append(InputEntry(time: down.time, lastTime: time, kind: .drag(down.button, from: down.point, to: point)))
            return
        }
        // The second click of a double-click updates the first rather than adding another line.
        if down.count > 1, let last = entries.indices.last, case .click(let button, let at, _) = entries[last].kind, button == down.button {
            entries[last].kind = .click(button, at: at, count: down.count)
            entries[last].lastTime = time
            return
        }
        entries.append(InputEntry(time: down.time, lastTime: time, kind: .click(down.button, at: down.point, count: down.count)))
    }

    /// The keys to show on screen at `now`: the last few, each for `window` seconds after it last changed.
    public func recentKeyLabels(at now: TimeInterval, window: TimeInterval = 2, limit: Int = 4) -> [String] {
        let recent = entries.filter { $0.isKey && now - $0.lastTime <= window && $0.lastTime <= now + 0.001 }
        return recent.suffix(limit).map { entry in
            switch entry.kind {
            case .typed(let text):
                if text.allSatisfy({ $0 == " " }) { return "Space" }
                return text.count > 20 ? "…" + String(text.suffix(20)).trimmingCharacters(in: .whitespaces) : text
            case .shortcut(let label, let count):
                return count > 1 ? "\(label) ×\(count)" : label
            case .click, .drag:
                return ""
            }
        }
    }

    /// The entries from `start` for `duration` seconds, with times measured from `start`. Entries up to `lead`
    /// seconds early are kept at 0: the first frame of a recording arrives a moment after it starts.
    public func rebased(start: TimeInterval, duration: TimeInterval, lead: TimeInterval = 0) -> InputTimeline {
        var copy = InputTimeline()
        copy.entries = entries.compactMap { entry in
            guard entry.time >= start - lead, entry.time <= start + duration else { return nil }
            var moved = entry
            moved.time = max(entry.time - start, 0)
            moved.lastTime = min(max(entry.lastTime - start, moved.time), duration)
            return moved
        }.sorted { $0.time < $1.time }
        return copy
    }
}

// MARK: Frames

/// When to grab stills from a recording, so an agent that can't watch video can still follow it:
/// the start, a moment after each thing you did, the end, and enough in between that no gap is too long.
public enum FramePlan {
    public static func times(for timeline: InputTimeline, duration: TimeInterval, settle: TimeInterval = 0.3,
                             minSpacing: TimeInterval = 0.5, maxGap: TimeInterval = 3, limit: Int = 16) -> [TimeInterval] {
        let end = max(duration - 0.05, 0)
        let actions = timeline.entries.map { min($0.lastTime + settle, end) }.sorted()
        var times: [TimeInterval] = [0]
        for t in actions + [end] where t - times.last! >= minSpacing - 0.0001 { times.append(t) }
        // The end always wins over an action frame just before it.
        if end > 0, times.last! < end {
            if times.count > 1 { times.removeLast() }
            times.append(end)
        }
        var filled: [TimeInterval] = [times[0]]
        for t in times.dropFirst() {
            let gap = t - filled.last!
            if gap > maxGap {
                let extra = Int((gap / maxGap).rounded(.up)) - 1
                let start = filled.last!
                for i in 1...extra { filled.append(start + gap * Double(i) / Double(extra + 1)) }
            }
            filled.append(t)
        }
        guard filled.count > limit, limit >= 2 else { return filled }
        return (0..<limit).map { i in filled[Int((Double(i) * Double(filled.count - 1) / Double(limit - 1)).rounded())] }
    }
}

// MARK: Summary

/// `summary.md` beside a recording: what's in it, then what you did and the frames, in time order.
public struct RecordingSummary {
    public var title: String
    public var videoFileName: String
    public var duration: TimeInterval
    public var videoSize: CGSize
    public var pointSize: CGSize
    public var timeline: InputTimeline
    /// Video time and path relative to the summary.
    public var frames: [(time: TimeInterval, path: String)]
    public var clicksRecorded: Bool
    public var keysRecorded: Bool

    public init(title: String, videoFileName: String, duration: TimeInterval, videoSize: CGSize, pointSize: CGSize,
                timeline: InputTimeline, frames: [(TimeInterval, String)], clicksRecorded: Bool, keysRecorded: Bool) {
        self.title = title
        self.videoFileName = videoFileName
        self.duration = duration
        self.videoSize = videoSize
        self.pointSize = pointSize
        self.timeline = timeline
        self.frames = frames.map { (time: $0.0, path: $0.1) }
        self.clicksRecorded = clicksRecorded
        self.keysRecorded = keysRecorded
    }

    public static func clock(_ t: TimeInterval) -> String {
        let tenths = Int((max(t, 0) * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }

    private static func point(_ p: CGPoint) -> String { "(\(Int(p.x.rounded())), \(Int(p.y.rounded())))" }

    private static func describe(_ kind: InputEntry.Kind) -> String {
        switch kind {
        case .typed(let text):
            return "Typed \"\(text)\""
        case .shortcut(let label, let count):
            return count > 1 ? "Pressed \(label) \(count) times" : "Pressed \(label)"
        case .click(let button, let at, let count):
            let name = button == .left ? "Left" : button == .right ? "Right" : "Middle"
            let what = count == 2 ? "double-click" : count > 2 ? "click ×\(count)" : "click"
            return "\(name) \(what) at \(point(at))"
        case .drag(let button, let from, let to):
            return "\(button == .left ? "Dragged" : "\(button.rawValue.capitalized)-dragged") from \(point(from)) to \(point(to))"
        }
    }

    public var markdown: String {
        var lines = ["# \(title)", ""]
        lines.append("[\(videoFileName)](<\(videoFileName)>), \(String(format: "%.1f", duration)) s, \(Int(videoSize.width)) × \(Int(videoSize.height)) px.")
        lines.append("")
        var about = "Positions are in points from the top-left of the recorded area, which is \(Int(pointSize.width.rounded())) × \(Int(pointSize.height.rounded())) points."
        let ratio = pointSize.width > 0 ? videoSize.width / pointSize.width : 1
        if abs(ratio - 1) > 0.01 { about += " The video is \(String(format: "%g", (ratio * 100).rounded() / 100))× that." }
        lines.append(about)
        if !clicksRecorded { lines.append("Clicks weren't recorded (turned off in Snap It's menu).") }
        if !keysRecorded { lines.append("Keys weren't recorded (turned off in Snap It's menu, or Snap It doesn't have Input Monitoring permission).") }
        lines += ["", "## What happened", ""]
        var items: [(TimeInterval, Int, String)] = []
        for frame in frames { items.append((frame.time, 0, "Frame: [\(frame.path)](<\(frame.path)>)")) }
        for entry in timeline.entries { items.append((entry.time, 1, Self.describe(entry.kind))) }
        for item in items.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }) {
            lines.append("- \(Self.clock(item.0)) \(item.2)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
