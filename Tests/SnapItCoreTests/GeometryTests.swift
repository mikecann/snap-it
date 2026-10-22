import XCTest
@testable import SnapItCore

final class GeometryTests: XCTestCase {
    // A 2560×1440 pt display left of and above the primary, like Mike's x = -2560, y = -269 (CG) display.
    let left = DisplayMapping(frame: CGRect(x: -2560, y: -171, width: 2560, height: 1440), pixelSize: CGSize(width: 5120, height: 2880))
    let primary = DisplayMapping(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), pixelSize: CGSize(width: 3456, height: 2234))
    let prompter = DisplayMapping(frame: CGRect(x: 1728, y: 200, width: 1024, height: 600), pixelSize: CGSize(width: 1024, height: 600))

    func testGlobalToLocalWithNegativeOrigin() {
        // Top-left corner of the display in AppKit global space is (minX, maxY).
        XCTAssertEqual(left.localPoint(fromGlobal: CGPoint(x: -2560, y: 1269)), CGPoint(x: 0, y: 0))
        XCTAssertEqual(left.localPoint(fromGlobal: CGPoint(x: -1, y: -171)), CGPoint(x: 2559, y: 1440))
        XCTAssertEqual(left.localPoint(fromGlobal: CGPoint(x: -1280, y: 549)), CGPoint(x: 1280, y: 720))
        let p = CGPoint(x: 311, y: 97)
        XCTAssertEqual(left.localPoint(fromGlobal: left.globalPoint(fromLocal: p)), p)
    }

    func testContainsPicksTheRightDisplay() {
        let displays = [left, primary, prompter]
        XCTAssertEqual(DisplayMapping.index(containing: CGPoint(x: -10, y: 0), in: displays), 0)
        XCTAssertEqual(DisplayMapping.index(containing: CGPoint(x: 10, y: 10), in: displays), 1)
        XCTAssertEqual(DisplayMapping.index(containing: CGPoint(x: 2000, y: 500), in: displays), 2)
        XCTAssertNil(DisplayMapping.index(containing: CGPoint(x: 5000, y: 500), in: displays))
    }

    func testScalesPerDisplay() {
        XCTAssertEqual(left.scale, 2)
        XCTAssertEqual(prompter.scale, 1)
        XCTAssertEqual(left.pixelRect(fromLocal: CGRect(x: 10, y: 20, width: 100, height: 50)), CGRect(x: 20, y: 40, width: 200, height: 100))
        XCTAssertEqual(prompter.pixelRect(fromLocal: CGRect(x: 10, y: 20, width: 100, height: 50)), CGRect(x: 10, y: 20, width: 100, height: 50))
    }

    func testPixelRectRoundsEdgesAndClamps() {
        let mixed = DisplayMapping(frame: CGRect(x: 0, y: 0, width: 100, height: 100), pixelSize: CGSize(width: 150, height: 150))
        XCTAssertEqual(mixed.pixelRect(fromLocal: CGRect(x: 0.5, y: 0.5, width: 10, height: 10)), CGRect(x: 1, y: 1, width: 15, height: 15))
        XCTAssertEqual(mixed.pixelRect(fromLocal: CGRect(x: 90, y: -5, width: 50, height: 20)), CGRect(x: 135, y: 0, width: 15, height: 23))
    }

    func testSelectionIsNormalisedAndClampedToItsDisplay() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertEqual(SelectionMath.rect(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 10, y: 20), square: false, within: bounds), CGRect(x: 10, y: 20, width: 40, height: 30))
        XCTAssertEqual(SelectionMath.rect(from: CGPoint(x: 150, y: 50), to: CGPoint(x: 400, y: -30), square: false, within: bounds), CGRect(x: 150, y: 0, width: 50, height: 50))
    }

    func testShiftConstrainsToSquareInsideBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertEqual(SelectionMath.rect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 70, y: 40), square: true, within: bounds), CGRect(x: 10, y: 10, width: 30, height: 30))
        XCTAssertEqual(SelectionMath.rect(from: CGPoint(x: 100, y: 50), to: CGPoint(x: 0, y: 500), square: true, within: bounds), CGRect(x: 50, y: 50, width: 50, height: 50))
    }
}

final class NamingTests: XCTestCase {
    let date: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 22; c.hour = 12; c.minute = 47; c.second = 51
        c.timeZone = TimeZone(identifier: "Australia/Sydney")
        return Calendar(identifier: .gregorian).date(from: c)!
    }()
    let tz = TimeZone(identifier: "Australia/Sydney")!

    func testFileNameMatchesMacOS() {
        XCTAssertEqual(ScreenshotNaming.fileName(date: date, scale: 2, timeZone: tz), "Screenshot 2026-10-22 at 12.47.51 PM@2x.png")
        XCTAssertEqual(ScreenshotNaming.fileName(date: date, scale: 1, timeZone: tz), "Screenshot 2026-10-22 at 12.47.51 PM.png")
        XCTAssertEqual(ScreenshotNaming.fileName(date: date, scale: 3, timeZone: tz), "Screenshot 2026-10-22 at 12.47.51 PM@3x.png")
        XCTAssertEqual(ScreenshotNaming.fileName(date: date, scale: 1.5, timeZone: tz), "Screenshot 2026-10-22 at 12.47.51 PM.png")
        XCTAssertEqual(ScreenshotNaming.fileName(date: date, scale: 2, copy: 2, timeZone: tz), "Screenshot 2026-10-22 at 12.47.51 PM (2)@2x.png")
        let morning = date.addingTimeInterval(-12 * 3600 + 5)
        XCTAssertEqual(ScreenshotNaming.fileName(date: morning, scale: 1, timeZone: tz), "Screenshot 2026-10-22 at 12.47.56 AM.png")
    }

    func testUniquifiesOnCollision() {
        let folder = URL(fileURLWithPath: "/tmp/shots")
        var taken: Set<String> = ["Screenshot 2026-10-22 at 12.47.51 PM@2x.png", "Screenshot 2026-10-22 at 12.47.51 PM (2)@2x.png"]
        let url = ScreenshotNaming.uniqueURL(in: folder, date: date, scale: 2, timeZone: tz) { taken.contains($0.lastPathComponent) }
        XCTAssertEqual(url.lastPathComponent, "Screenshot 2026-10-22 at 12.47.51 PM (3)@2x.png")
        taken = []
        XCTAssertEqual(ScreenshotNaming.uniqueURL(in: folder, date: date, scale: 2, timeZone: tz) { taken.contains($0.lastPathComponent) }.lastPathComponent,
                       "Screenshot 2026-10-22 at 12.47.51 PM@2x.png")
    }
}
