import XCTest
@testable import SnapItCore

final class RecordingTests: XCTestCase {
    // MARK: Naming and size

    func testRecordingFolderAndVideoNames() {
        let utc = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_794_000_000) // 2026-11-06 21:20:00 UTC
        let folder = URL(fileURLWithPath: "/tmp/shots", isDirectory: true)
        let url = RecordingNaming.uniqueFolder(in: folder, date: date, timeZone: utc) { _ in false }
        XCTAssertEqual(url.lastPathComponent, "Screen Recording 2026-11-06 at 9.20.00 PM")
        XCTAssertEqual(RecordingNaming.videoURL(inFolder: url).lastPathComponent, "Screen Recording 2026-11-06 at 9.20.00 PM.mp4")
        let taken = RecordingNaming.uniqueFolder(in: folder, date: date, timeZone: utc) { $0 == url }
        XCTAssertEqual(taken.lastPathComponent, "Screen Recording 2026-11-06 at 9.20.00 PM (2)")
    }

    func testOutputSizeIsEvenAndFitsTheEncoder() {
        XCTAssertEqual(VideoGeometry.outputSize(for: CGSize(width: 1481, height: 563)), CGSize(width: 1480, height: 562))
        XCTAssertEqual(VideoGeometry.outputSize(for: CGSize(width: 1, height: 1)), CGSize(width: 2, height: 2))
        // A whole 5K display scales down to 4K, keeping its shape.
        XCTAssertEqual(VideoGeometry.outputSize(for: CGSize(width: 5120, height: 2880)), CGSize(width: 3840, height: 2160))
        // Portrait areas get the same limit turned on its side.
        XCTAssertEqual(VideoGeometry.outputSize(for: CGSize(width: 1000, height: 4000)), CGSize(width: 960, height: 3840))
    }

    func testCaptureModeToggles() {
        XCTAssertEqual(CaptureMode.screenshot.toggled, .record)
        XCTAssertEqual(CaptureMode.record.toggled, .screenshot)
    }

    // MARK: Key labels

    func testPlainTypingIsText() {
        XCTAssertEqual(KeyNames.press(keyCode: 4, modifiers: [], typed: "h", baseKey: "h"), .text("h"))
        XCTAssertEqual(KeyNames.press(keyCode: 4, modifiers: [.shift], typed: "H", baseKey: "h"), .text("H"))
        XCTAssertEqual(KeyNames.press(keyCode: 49, modifiers: [], typed: " ", baseKey: " "), .text(" "))
    }

    func testShortcutsAndSpecialKeys() {
        XCTAssertEqual(KeyNames.press(keyCode: 40, modifiers: [.command], typed: "k", baseKey: "k"), .shortcut("⌘K"))
        XCTAssertEqual(KeyNames.press(keyCode: 6, modifiers: [.command, .shift], typed: "z", baseKey: "z"), .shortcut("⇧⌘Z"))
        XCTAssertEqual(KeyNames.press(keyCode: 0, modifiers: [.control, .option, .shift, .command], typed: "a", baseKey: "a"), .shortcut("⌃⌥⇧⌘A"))
        XCTAssertEqual(KeyNames.press(keyCode: 36, modifiers: [], typed: "\r", baseKey: "\r"), .shortcut("Return"))
        XCTAssertEqual(KeyNames.press(keyCode: 48, modifiers: [.shift], typed: "\t", baseKey: "\t"), .shortcut("⇧Tab"))
        XCTAssertEqual(KeyNames.press(keyCode: 51, modifiers: [], typed: "\u{7f}", baseKey: "\u{7f}"), .shortcut("⌫"))
        XCTAssertEqual(KeyNames.press(keyCode: 123, modifiers: [.command], typed: "", baseKey: ""), .shortcut("⌘←"))
        XCTAssertEqual(KeyNames.press(keyCode: 49, modifiers: [.command], typed: " ", baseKey: " "), .shortcut("⌘Space"))
        XCTAssertEqual(KeyNames.press(keyCode: 122, modifiers: [], typed: "", baseKey: ""), .shortcut("F1"))
        // A key with no name and nothing typed shows nothing rather than a blank chip.
        XCTAssertNil(KeyNames.press(keyCode: 200, modifiers: [], typed: "", baseKey: ""))
    }

    func testSnapItsOwnHotkeysAreRecognised() {
        XCTAssertTrue(KeyNames.isSnapItHotkey(keyCode: 21, modifiers: [.command, .shift])) // ⌘⇧4
        XCTAssertTrue(KeyNames.isSnapItHotkey(keyCode: 20, modifiers: [.command, .shift])) // ⌘⇧3
        XCTAssertFalse(KeyNames.isSnapItHotkey(keyCode: 21, modifiers: [.command]))
    }

    // MARK: Timeline

    func testTypingMergesIntoOneEntryUntilAPause() {
        var timeline = InputTimeline()
        for (i, c) in "hello".enumerated() { timeline.key(.text(String(c)), at: 1 + Double(i) * 0.1) }
        timeline.key(.text(" "), at: 1.6)
        timeline.key(.text("w"), at: 1.7)
        timeline.key(.text("x"), at: 5)
        XCTAssertEqual(timeline.entries.map(\.kind), [.typed("hello w"), .typed("x")])
        XCTAssertEqual(timeline.entries[0].time, 1)
        XCTAssertEqual(timeline.entries[0].lastTime, 1.7, accuracy: 0.0001)
    }

    func testRepeatedShortcutsCount() {
        var timeline = InputTimeline()
        timeline.key(.text("ab"), at: 0)
        timeline.key(.shortcut("⌫"), at: 0.5)
        timeline.key(.shortcut("⌫"), at: 0.7)
        timeline.key(.shortcut("⌫"), at: 0.9)
        timeline.key(.shortcut("⌘Z"), at: 1.0)
        timeline.key(.shortcut("⌫"), at: 3)
        XCTAssertEqual(timeline.entries.map(\.kind), [.typed("ab"), .shortcut("⌫", count: 3), .shortcut("⌘Z", count: 1), .shortcut("⌫", count: 1)])
    }

    func testClicksDoubleClicksAndDrags() {
        var timeline = InputTimeline()
        timeline.mouseDown(.left, at: CGPoint(x: 10, y: 10), time: 1, clickCount: 1)
        timeline.mouseUp(.left, at: CGPoint(x: 11, y: 10), time: 1.05)
        timeline.mouseDown(.left, at: CGPoint(x: 11, y: 10), time: 1.2, clickCount: 2)
        timeline.mouseUp(.left, at: CGPoint(x: 11, y: 10), time: 1.25)
        timeline.mouseDown(.right, at: CGPoint(x: 50, y: 60), time: 2, clickCount: 1)
        timeline.mouseUp(.right, at: CGPoint(x: 50, y: 60), time: 2.1)
        timeline.mouseDown(.left, at: CGPoint(x: 0, y: 0), time: 3, clickCount: 1)
        timeline.mouseUp(.left, at: CGPoint(x: 100, y: 40), time: 3.5)
        XCTAssertEqual(timeline.entries.map(\.kind), [
            .click(.left, at: CGPoint(x: 10, y: 10), count: 2),
            .click(.right, at: CGPoint(x: 50, y: 60), count: 1),
            .drag(.left, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 40)),
        ])
    }

    func testAButtonStillHeldWhenRecordingStopsCountsAsAClick() {
        var timeline = InputTimeline()
        timeline.mouseDown(.left, at: CGPoint(x: 5, y: 6), time: 1, clickCount: 1)
        timeline.finish()
        XCTAssertEqual(timeline.entries.map(\.kind), [.click(.left, at: CGPoint(x: 5, y: 6), count: 1)])
    }

    func testRecentKeyLabelsForTheOnScreenKeys() {
        var timeline = InputTimeline()
        timeline.key(.text("hi"), at: 0)
        timeline.key(.shortcut("⌘K"), at: 1)
        timeline.key(.shortcut("⌫"), at: 1.2)
        timeline.key(.shortcut("⌫"), at: 1.3)
        timeline.mouseDown(.left, at: .zero, time: 1.4, clickCount: 1)
        timeline.mouseUp(.left, at: .zero, time: 1.5)
        timeline.key(.text(" "), at: 1.6)
        XCTAssertEqual(timeline.recentKeyLabels(at: 1.7), ["hi", "⌘K", "⌫ ×2", "Space"])
        XCTAssertEqual(timeline.recentKeyLabels(at: 2.9), ["⌘K", "⌫ ×2", "Space"])
        XCTAssertEqual(timeline.recentKeyLabels(at: 10), [])
        XCTAssertEqual(timeline.recentKeyLabels(at: 1.7, limit: 2), ["⌫ ×2", "Space"])
    }

    func testLongTypingKeepsTheEndOnScreen() {
        var timeline = InputTimeline()
        timeline.key(.text("the quick brown fox jumps over"), at: 0)
        XCTAssertEqual(timeline.recentKeyLabels(at: 0.1), ["…brown fox jumps over"])
    }

    func testRebasedTimelineForTheVideoAndForATrim() {
        var timeline = InputTimeline()
        timeline.key(.shortcut("⌘A"), at: 99.8) // just before the first frame
        timeline.key(.shortcut("⌘B"), at: 101)
        timeline.key(.shortcut("⌘C"), at: 104)
        timeline.key(.shortcut("⌘D"), at: 110)
        let video = timeline.rebased(start: 100, duration: 8, lead: 0.5)
        XCTAssertEqual(video.entries.map(\.time), [0, 1, 4])
        let trimmed = video.rebased(start: 0.5, duration: 2)
        XCTAssertEqual(trimmed.entries.map(\.kind), [.shortcut("⌘B", count: 1)])
        XCTAssertEqual(trimmed.entries[0].time, 0.5, accuracy: 0.0001)
    }

    // MARK: Frames

    func testFramesLandAfterEachActionAndFillLongGaps() {
        var timeline = InputTimeline()
        timeline.mouseDown(.left, at: .zero, time: 1, clickCount: 1)
        timeline.mouseUp(.left, at: .zero, time: 1.1)
        timeline.key(.shortcut("⌘K"), at: 1.2) // too close to the click to need its own frame
        timeline.key(.text("x"), at: 9)
        let times = FramePlan.times(for: timeline, duration: 10)
        XCTAssertEqual(times.first, 0)
        XCTAssertEqual(times.last!, 9.95, accuracy: 0.001)
        XCTAssertTrue(times.contains { abs($0 - 1.4) < 0.001 }, "\(times)")
        XCTAssertTrue(times.contains { abs($0 - 9.3) < 0.001 }, "\(times)")
        for (a, b) in zip(times, times.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 0.5 - 0.0001, "\(times)")
            XCTAssertLessThanOrEqual(b - a, 3 + 0.0001, "\(times)")
        }
    }

    func testFramesAreCappedButKeepTheEnds() {
        let times = FramePlan.times(for: InputTimeline(), duration: 120, limit: 10)
        XCTAssertEqual(times.count, 10)
        XCTAssertEqual(times.first, 0)
        XCTAssertEqual(times.last!, 119.95, accuracy: 0.001)
    }

    func testAShortClipStillGetsAFrame() {
        XCTAssertEqual(FramePlan.times(for: InputTimeline(), duration: 0.02), [0])
    }

    // MARK: Summary

    func testSummaryReadsInTimeOrder() {
        var timeline = InputTimeline()
        timeline.mouseDown(.left, at: CGPoint(x: 340.4, y: 120), time: 1.2, clickCount: 1)
        timeline.mouseUp(.left, at: CGPoint(x: 340.4, y: 120), time: 1.3)
        timeline.key(.text("hello"), at: 2)
        timeline.key(.shortcut("⌫"), at: 3)
        timeline.key(.shortcut("⌫"), at: 3.1)
        let summary = RecordingSummary(
            title: "Screen Recording 2026-11-12 at 11.06.29 AM",
            videoFileName: "Screen Recording 2026-11-12 at 11.06.29 AM.mp4",
            duration: 4.26, videoSize: CGSize(width: 1480, height: 560), pointSize: CGSize(width: 740, height: 280),
            timeline: timeline, frames: [(0, "frames/frame-01-0.0s.png"), (1.6, "frames/frame-02-1.6s.png")],
            clicksRecorded: true, keysRecorded: true)
        let md = summary.markdown
        XCTAssertTrue(md.hasPrefix("# Screen Recording 2026-11-12 at 11.06.29 AM\n"), md)
        XCTAssertTrue(md.contains("[Screen Recording 2026-11-12 at 11.06.29 AM.mp4](<Screen Recording 2026-11-12 at 11.06.29 AM.mp4>), 4.3 s, 1480 × 560 px"), md)
        XCTAssertTrue(md.contains("740 × 280"), md)
        XCTAssertTrue(md.contains("2× that"), md)
        let lines = md.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }
        XCTAssertEqual(lines, [
            "- 0:00.0 Frame: [frames/frame-01-0.0s.png](<frames/frame-01-0.0s.png>)",
            "- 0:01.2 Left click at (340, 120)",
            "- 0:01.6 Frame: [frames/frame-02-1.6s.png](<frames/frame-02-1.6s.png>)",
            "- 0:02.0 Typed \"hello\"",
            "- 0:03.0 Pressed ⌫ 2 times",
        ])
    }

    func testSummarySaysWhenKeysWereNotRecorded() {
        let summary = RecordingSummary(title: "T", videoFileName: "T.mp4", duration: 1, videoSize: CGSize(width: 100, height: 100),
                                       pointSize: CGSize(width: 100, height: 100), timeline: InputTimeline(), frames: [],
                                       clicksRecorded: true, keysRecorded: false)
        XCTAssertTrue(summary.markdown.contains("Keys weren't recorded"), summary.markdown)
        XCTAssertFalse(summary.markdown.contains("× that"), summary.markdown)
    }

    func testRecordingSettingsDefaultOn() {
        let defaults = UserDefaults(suiteName: "snap-it-tests-\(UUID().uuidString)")!
        let settings = SnapItSettings(defaults: defaults)
        XCTAssertTrue(settings.showClicks)
        XCTAssertTrue(settings.showKeys)
        settings.showKeys = false
        XCTAssertFalse(settings.showKeys)
    }
}
