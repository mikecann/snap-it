import XCTest
@testable import SnapItCore

final class ShapeTests: XCTestCase {
    func testArrowTapersFromTailToHead() {
        let path = ShapePaths.arrowPath(from: CGPoint(x: 0, y: 100), to: CGPoint(x: 300, y: 100), thickness: 7)
        // Head tip and barbs are filled.
        XCTAssertTrue(path.contains(CGPoint(x: 298, y: 100)))
        XCTAssertTrue(path.contains(CGPoint(x: 275, y: 100 + 12)))
        // Shaft is thinner near the tail than near the head.
        func halfWidth(atX x: CGFloat) -> CGFloat {
            var w: CGFloat = 0
            while path.contains(CGPoint(x: x, y: 100 + w + 0.1)) { w += 0.1 }
            return w
        }
        let nearTail = halfWidth(atX: 20), nearHead = halfWidth(atX: 250)
        XCTAssertGreaterThan(nearTail, 0.5)
        XCTAssertLessThan(nearTail, 3)
        XCTAssertGreaterThan(nearHead, nearTail * 1.6)
        // Notched back: the centre line just behind the barbs is empty outside the shaft.
        XCTAssertFalse(path.contains(CGPoint(x: 300 - 7 * 4.6 + 1, y: 100 + 14)))
        XCTAssertFalse(path.contains(CGPoint(x: 100, y: 120)))
    }

    func testShortArrowKeepsItsHeadInside() {
        let path = ShapePaths.arrowPath(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 20, y: 0), thickness: 7)
        XCTAssertGreaterThanOrEqual(path.boundingBoxOfPath.minX, -4)
        XCTAssertLessThanOrEqual(path.boundingBoxOfPath.maxX, 20.01)
    }

    func testSnap45() {
        let s = ShapePaths.snap45(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 10))
        XCTAssertEqual(s.x, hypot(100, 10), accuracy: 0.001)
        XCTAssertEqual(s.y, 0, accuracy: 0.001)
        let d = ShapePaths.snap45(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 50, y: 45))
        XCTAssertEqual(d.x, d.y, accuracy: 0.001)
        XCTAssertEqual(ShapePaths.squared(from: CGPoint(x: 10, y: 10), to: CGPoint(x: -30, y: 25)), CGPoint(x: -5, y: 25))
    }

    func testHitTesting() {
        let arrow = Annotation(kind: .arrow, points: [CGPoint(x: 0, y: 50), CGPoint(x: 200, y: 50)], color: .hotPink, thickness: 7)
        XCTAssertTrue(arrow.hitTest(CGPoint(x: 100, y: 52), tolerance: 3))
        XCTAssertTrue(arrow.hitTest(CGPoint(x: 195, y: 50), tolerance: 3))
        XCTAssertFalse(arrow.hitTest(CGPoint(x: 100, y: 70), tolerance: 3))
        let rect = Annotation(kind: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 60)], color: .hotPink, thickness: 7)
        XCTAssertTrue(rect.hitTest(CGPoint(x: 10, y: 35), tolerance: 3))
        XCTAssertFalse(rect.hitTest(CGPoint(x: 60, y: 35), tolerance: 3), "stroked rectangles are hollow")
        let filled = Annotation(kind: .filledRectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 60)], color: .hotPink, thickness: 7)
        XCTAssertTrue(filled.hitTest(CGPoint(x: 60, y: 35), tolerance: 3))
        let ellipse = Annotation(kind: .ellipse, points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100)], color: .hotPink, thickness: 7)
        XCTAssertTrue(ellipse.hitTest(CGPoint(x: 50, y: 1), tolerance: 3))
        XCTAssertFalse(ellipse.hitTest(CGPoint(x: 2, y: 2), tolerance: 3))
        let text = Annotation(kind: .text, points: [CGPoint(x: 10, y: 10)], color: .hotPink, thickness: 7, text: "Hello", fontSize: 35)
        XCTAssertTrue(text.hitTest(CGPoint(x: 20, y: 25), tolerance: 0))
        XCTAssertFalse(text.hitTest(CGPoint(x: 5, y: 5), tolerance: 0))
    }

    func testHandlesReshape() {
        let arrow = Annotation(kind: .arrow, points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)], color: .hotPink, thickness: 7)
        XCTAssertEqual(arrow.handles, [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)])
        XCTAssertEqual(arrow.movingHandle(1, to: CGPoint(x: 40, y: 5)).points, [CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 5)])
        let rect = Annotation(kind: .rectangle, points: [CGPoint(x: 30, y: 30), CGPoint(x: 10, y: 10)], color: .hotPink, thickness: 7)
        XCTAssertEqual(rect.handles, [CGPoint(x: 10, y: 10), CGPoint(x: 30, y: 10), CGPoint(x: 30, y: 30), CGPoint(x: 10, y: 30)])
        // Dragging the top-right corner keeps the bottom-left fixed.
        XCTAssertEqual(rect.movingHandle(1, to: CGPoint(x: 50, y: 0)).rect, CGRect(x: 10, y: 0, width: 40, height: 30))
        let pen = Annotation(kind: .pen, points: [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5)], color: .hotPink, thickness: 7)
        XCTAssertTrue(pen.handles.isEmpty)
        XCTAssertEqual(pen.offsetBy(dx: 1, dy: 2).points, [CGPoint(x: 1, y: 2), CGPoint(x: 6, y: 7)])
    }

    func testBoxResizeKeepsTheAnchorWhenDraggedAcrossIt() {
        for kind in [ShapeKind.rectangle, .filledRectangle, .ellipse, .pixelate] {
            let start = Annotation(kind: kind, points: [CGPoint(x: 10, y: 10), CGPoint(x: 110, y: 110)], color: .hotPink, thickness: 7)
            let anchor = try! XCTUnwrap(start.anchor(forHandle: 0))
            XCTAssertEqual(anchor, CGPoint(x: 110, y: 110))
            var a = start
            for p in [CGPoint(x: 60, y: 60), CGPoint(x: 105, y: 105), CGPoint(x: 120, y: 120), CGPoint(x: 135, y: 140), CGPoint(x: 150, y: 150)] {
                a = a.movingHandle(0, to: p, anchor: anchor)
            }
            XCTAssertEqual(a.rect, CGRect(x: 110, y: 110, width: 40, height: 40), "\(kind)")
        }
    }

    func testArrowAnchorIsTheOtherEnd() {
        let arrow = Annotation(kind: .arrow, points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)], color: .hotPink, thickness: 7)
        XCTAssertEqual(arrow.anchor(forHandle: 0), CGPoint(x: 10, y: 10))
        XCTAssertEqual(arrow.anchor(forHandle: 1), CGPoint(x: 0, y: 0))
        XCTAssertNil(arrow.anchor(forHandle: 2))
    }

    func testDegenerateShapes() {
        XCTAssertTrue(Annotation(kind: .arrow, points: [.zero, CGPoint(x: 1, y: 0)], color: .hotPink, thickness: 7).isDegenerate)
        XCTAssertTrue(Annotation(kind: .rectangle, points: [.zero, CGPoint(x: 40, y: 1)], color: .hotPink, thickness: 7).isDegenerate)
        XCTAssertTrue(Annotation(kind: .pen, points: [.zero], color: .hotPink, thickness: 7).isDegenerate)
        XCTAssertTrue(Annotation(kind: .text, points: [.zero], color: .hotPink, thickness: 7, text: "  ", fontSize: 35).isDegenerate)
        XCTAssertFalse(Annotation(kind: .arrow, points: [.zero, CGPoint(x: 30, y: 0)], color: .hotPink, thickness: 7).isDegenerate)
    }

    func testToolShortcuts() {
        XCTAssertEqual(Tool(shortcut: "a"), .arrow)
        XCTAssertEqual(Tool(shortcut: "R"), .rectangle)
        XCTAssertEqual(Tool(shortcut: "f"), .filledRectangle)
        XCTAssertEqual(Tool(shortcut: "o"), .ellipse)
        XCTAssertEqual(Tool(shortcut: "l"), .line)
        XCTAssertEqual(Tool(shortcut: "t"), .text)
        XCTAssertEqual(Tool(shortcut: "p"), .pen)
        XCTAssertEqual(Tool(shortcut: "h"), .highlighter)
        XCTAssertEqual(Tool(shortcut: "x"), .pixelate)
        XCTAssertEqual(Tool(shortcut: "c"), .crop)
        XCTAssertNil(Tool(shortcut: "z"))
    }
}

final class DocumentTests: XCTestCase {
    func arrow(_ x: CGFloat) -> Annotation {
        Annotation(kind: .arrow, points: [CGPoint(x: x, y: 0), CGPoint(x: x + 50, y: 50)], color: .hotPink, thickness: 7)
    }

    func testUndoRedoAndDirtyTracking() {
        let doc = AnnotationDocument(imageSize: CGSize(width: 100, height: 100))
        XCTAssertFalse(doc.hasUnsavedChanges)
        XCTAssertFalse(doc.canUndo)
        let a = arrow(0)
        doc.add(a)
        XCTAssertTrue(doc.hasUnsavedChanges)
        doc.update(a.offsetBy(dx: 5, dy: 0))
        XCTAssertEqual(doc.state.annotations.first?.points.first, CGPoint(x: 5, y: 0))
        doc.undo()
        XCTAssertEqual(doc.state.annotations.first?.points.first, CGPoint(x: 0, y: 0))
        doc.undo()
        XCTAssertTrue(doc.state.annotations.isEmpty)
        XCTAssertFalse(doc.hasUnsavedChanges, "undoing everything is back to the saved file")
        doc.redo(); doc.redo()
        XCTAssertEqual(doc.state.annotations.first?.points.first, CGPoint(x: 5, y: 0))
        doc.markSaved()
        XCTAssertFalse(doc.hasUnsavedChanges)
        doc.remove(id: a.id)
        XCTAssertTrue(doc.state.annotations.isEmpty)
        XCTAssertTrue(doc.hasUnsavedChanges)
        doc.undo()
        XCTAssertFalse(doc.hasUnsavedChanges)
    }

    func testSavedStateIsWhatWasWrittenNotWhatIsCurrent() {
        let doc = AnnotationDocument(imageSize: CGSize(width: 100, height: 100))
        doc.add(arrow(0))
        let written = doc.state
        doc.add(arrow(20))
        // The write of `written` finishes after a further edit: still unsaved.
        doc.markSaved(written)
        XCTAssertTrue(doc.hasUnsavedChanges)
        doc.undo()
        XCTAssertFalse(doc.hasUnsavedChanges)
    }

    func testNeedsSaveWithoutEdits() {
        let doc = AnnotationDocument(imageSize: CGSize(width: 100, height: 100))
        doc.markNeedsSave()
        XCTAssertTrue(doc.hasUnsavedChanges, "a capture whose first write failed still needs saving")
        doc.markSaved()
        XCTAssertFalse(doc.hasUnsavedChanges)
    }

    func testLiveGestureIsOneUndoStep() {
        let doc = AnnotationDocument(imageSize: CGSize(width: 100, height: 100))
        let start = doc.state
        var a = arrow(0)
        for i in 1...10 {
            a.points[1] = CGPoint(x: CGFloat(i * 10), y: 0)
            var s = start; s.annotations = [a]
            doc.setLive(s)
        }
        doc.commit(doc.state, from: start)
        XCTAssertTrue(doc.canUndo)
        doc.undo()
        XCTAssertEqual(doc.state, start)
        XCTAssertFalse(doc.canUndo)
        // Committing an unchanged state records nothing.
        doc.commit(doc.state, from: doc.state)
        XCTAssertFalse(doc.canUndo)
    }

    func testNewChangeClearsRedo() {
        let doc = AnnotationDocument(imageSize: CGSize(width: 100, height: 100))
        doc.add(arrow(0)); doc.undo()
        XCTAssertTrue(doc.canRedo)
        doc.add(arrow(10))
        XCTAssertFalse(doc.canRedo)
    }

    func testTopmostHit() {
        let doc = AnnotationDocument(imageSize: CGSize(width: 100, height: 100))
        let bottom = Annotation(kind: .filledRectangle, points: [.zero, CGPoint(x: 100, y: 100)], color: .hotPink, thickness: 7)
        let top = Annotation(kind: .filledRectangle, points: [CGPoint(x: 40, y: 40), CGPoint(x: 60, y: 60)], color: .hotPink, thickness: 7)
        doc.add(bottom); doc.add(top)
        XCTAssertEqual(doc.topmostAnnotation(at: CGPoint(x: 50, y: 50), tolerance: 0)?.id, top.id)
        XCTAssertEqual(doc.topmostAnnotation(at: CGPoint(x: 10, y: 10), tolerance: 0)?.id, bottom.id)
    }

    func testCropIsUndoable() {
        let doc = AnnotationDocument(imageSize: CGSize(width: 100, height: 100))
        var s = doc.state; s.crop = CGRect(x: 10, y: 10, width: 50, height: 50)
        doc.commit(s)
        XCTAssertEqual(doc.state.crop, CGRect(x: 10, y: 10, width: 50, height: 50))
        doc.undo()
        XCTAssertNil(doc.state.crop)
    }
}

final class CropTests: XCTestCase {
    let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)

    func testResizeFromHandlesStaysInBounds() {
        let r = CGRect(x: 50, y: 20, width: 100, height: 60)
        XCTAssertEqual(CropMath.resize(r, handle: .topLeft, to: CGPoint(x: 40, y: 10), within: bounds), CGRect(x: 40, y: 10, width: 110, height: 70))
        XCTAssertEqual(CropMath.resize(r, handle: .right, to: CGPoint(x: 500, y: 0), within: bounds), CGRect(x: 50, y: 20, width: 150, height: 60))
        XCTAssertEqual(CropMath.resize(r, handle: .bottom, to: CGPoint(x: 0, y: 5), within: bounds).height, CropMath.minimumSize)
        XCTAssertEqual(CropMath.resize(r, handle: .bottomRight, to: CGPoint(x: 160, y: 90), within: bounds), CGRect(x: 50, y: 20, width: 110, height: 70))
    }

    func testMoveIsClamped() {
        let r = CGRect(x: 50, y: 20, width: 100, height: 60)
        XCTAssertEqual(CropMath.move(r, by: CGSize(width: 500, height: -500), within: bounds), CGRect(x: 100, y: 0, width: 100, height: 60))
    }

    func testNormalisedCropSnapsToPixelsAndDropsFullImage() {
        XCTAssertNil(CropMath.normalized(bounds, imageBounds: bounds, scale: 2))
        XCTAssertEqual(CropMath.normalized(CGRect(x: 10.2, y: 10.3, width: 50.1, height: 20), imageBounds: bounds, scale: 2), CGRect(x: 10, y: 10.5, width: 50.5, height: 20))
        XCTAssertNil(CropMath.normalized(CGRect(x: 10, y: 10, width: 0.1, height: 20), imageBounds: bounds, scale: 2))
    }
}

final class SettingsTests: XCTestCase {
    func testDefaultsAndPersistence() {
        let suite = "snap-it-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = SnapItSettings(defaults: defaults, home: URL(fileURLWithPath: "/Users/test"))
        XCTAssertEqual(settings.saveFolder.path, "/Users/test/Screenshots")
        XCTAssertEqual(settings.lastTool, .arrow)
        XCTAssertEqual(settings.color, .hotPink)
        XCTAssertEqual(settings.thickness, 7)
        XCTAssertEqual(settings.textSize, 35)
        settings.lastTool = .highlighter
        settings.color = RGBAColor(red: 0, green: 0.5, blue: 1, alpha: 1)
        settings.thickness = 3
        settings.textSize = 48
        settings = SnapItSettings(defaults: defaults, home: URL(fileURLWithPath: "/Users/test"))
        XCTAssertEqual(settings.lastTool, .highlighter)
        XCTAssertEqual(settings.color, RGBAColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        XCTAssertEqual(settings.thickness, 3)
        XCTAssertEqual(settings.textSize, 48)
        settings.lastTool = .crop
        XCTAssertEqual(SnapItSettings(defaults: defaults, home: URL(fileURLWithPath: "/Users/test")).lastTool, .highlighter, "crop is never the starting tool")
    }
}
