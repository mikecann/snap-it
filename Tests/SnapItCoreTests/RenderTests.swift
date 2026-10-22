import XCTest
import ImageIO
@testable import SnapItCore

/// Builds an sRGB test image in pixels with a solid colour, or a horizontal gradient when `gradient` is set.
func makeImage(width: Int, height: Int, gradient: Bool = false, color: (UInt8, UInt8, UInt8) = (20, 120, 200)) -> CGImage {
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height { for x in 0..<width {
        let i = (y * width + x) * 4
        if gradient {
            bytes[i] = UInt8((x * 255) / max(width - 1, 1)); bytes[i + 1] = UInt8((y * 255) / max(height - 1, 1)); bytes[i + 2] = 0
        } else {
            bytes[i] = color.0; bytes[i + 1] = color.1; bytes[i + 2] = color.2
        }
    } }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

/// Reads RGBA pixels with a top-left origin.
struct Pixels {
    let width: Int, height: Int, bytes: [UInt8]
    init(_ image: CGImage) {
        width = image.width; height = image.height
        var b = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &b, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = b
    }
    subscript(x: Int, y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }
}

func assertColor(_ c: (Int, Int, Int), _ expected: (Int, Int, Int), tolerance: Int = 3, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(c.0 - expected.0), tolerance, "\(c) vs \(expected)", file: file, line: line)
    XCTAssertLessThanOrEqual(abs(c.1 - expected.1), tolerance, "\(c) vs \(expected)", file: file, line: line)
    XCTAssertLessThanOrEqual(abs(c.2 - expected.2), tolerance, "\(c) vs \(expected)", file: file, line: line)
}

final class RenderTests: XCTestCase {
    let pink = (255, 0, 165), base = (20, 120, 200)

    func testFlattenDrawsAnnotationsAtPixelScale() throws {
        // 200×100 pt at 2x = 400×200 px.
        let renderer = AnnotationRenderer(baseImage: makeImage(width: 400, height: 200), scale: 2)
        var state = EditorState()
        state.annotations.append(Annotation(kind: .arrow, points: [CGPoint(x: 10, y: 50), CGPoint(x: 150, y: 50)], color: .hotPink, thickness: 7))
        state.annotations.append(Annotation(kind: .filledRectangle, points: [CGPoint(x: 160, y: 10), CGPoint(x: 190, y: 30)], color: .hotPink, thickness: 7))
        let out = try XCTUnwrap(renderer.flatten(state))
        XCTAssertEqual(out.width, 400); XCTAssertEqual(out.height, 200)
        let px = Pixels(out)
        assertColor(px[290, 100], pink)        // just behind the arrow tip (145 pt)
        assertColor(px[250, 100 + 25], pink)   // inside a barb
        assertColor(px[60, 100], pink)         // shaft
        assertColor(px[350, 40], pink)         // filled rectangle
        assertColor(px[2, 2], base)            // untouched corner
        assertColor(px[399, 199], base)
        assertColor(px[60, 130], base)         // away from the shaft
    }

    func testSevenPointLineIsFourteenPixelsAt2x() throws {
        let renderer = AnnotationRenderer(baseImage: makeImage(width: 200, height: 200), scale: 2)
        var state = EditorState()
        state.annotations.append(Annotation(kind: .line, points: [CGPoint(x: 10, y: 50), CGPoint(x: 90, y: 50)], color: .hotPink, thickness: 7))
        let px = Pixels(try XCTUnwrap(renderer.flatten(state)))
        var covered = 0
        for y in 0..<200 where px[100, y] == (255, 0, 165) { covered += 1 }
        XCTAssertEqual(covered, 14, accuracy: 1)
    }

    func testHighlighterKeepsContentReadable() throws {
        let renderer = AnnotationRenderer(baseImage: makeImage(width: 100, height: 100, color: (255, 255, 255)), scale: 1)
        var state = EditorState()
        state.annotations.append(Annotation(kind: .highlighter, points: [CGPoint(x: 10, y: 50), CGPoint(x: 90, y: 50)], color: .hotPink, thickness: 7))
        let px = Pixels(try XCTUnwrap(renderer.flatten(state)))
        let c = px[50, 50]
        // Tinted pink over white, but not solid pink.
        XCTAssertEqual(c.0, 255, accuracy: 3)
        XCTAssertLessThan(c.1, 230); XCTAssertGreaterThan(c.1, 100)
        assertColor(px[50, 10], (255, 255, 255))
    }

    func testTextIsDrawn() throws {
        let renderer = AnnotationRenderer(baseImage: makeImage(width: 400, height: 200, color: (0, 0, 0)), scale: 2)
        var state = EditorState()
        state.annotations.append(Annotation(kind: .text, points: [CGPoint(x: 10, y: 10)], color: .hotPink, thickness: 7, text: "███", fontSize: 35))
        let px = Pixels(try XCTUnwrap(renderer.flatten(state)))
        var pinkCount = 0
        for y in stride(from: 0, to: 200, by: 2) { for x in stride(from: 0, to: 400, by: 2) where px[x, y].0 > 200 && px[x, y].1 < 40 { pinkCount += 1 } }
        XCTAssertGreaterThan(pinkCount, 100)
        assertColor(px[399, 199], (0, 0, 0))
        // Text is upright: glyphs start near the top of their box, not mirrored to the bottom of the image.
        var topPink = false
        for x in stride(from: 20, to: 200, by: 2) where px[x, 60].0 > 200 { topPink = true }
        XCTAssertTrue(topPink)
    }

    func testCropAppliesOnExport() throws {
        let renderer = AnnotationRenderer(baseImage: makeImage(width: 200, height: 100, gradient: true), scale: 2)
        var state = EditorState()
        state.crop = CGRect(x: 10, y: 5, width: 40, height: 20)
        let out = try XCTUnwrap(renderer.flatten(state))
        XCTAssertEqual(out.width, 80); XCTAssertEqual(out.height, 40)
        let full = Pixels(makeImage(width: 200, height: 100, gradient: true)), cropped = Pixels(out)
        XCTAssertEqual(cropped[0, 0].0, full[20, 10].0)
        XCTAssertEqual(cropped[0, 0].1, full[20, 10].1)
        XCTAssertEqual(cropped[79, 39].0, full[99, 49].0)
    }

    func testPixelateIsUniformPerBlock() throws {
        let image = makeImage(width: 200, height: 100, gradient: true)
        let renderer = AnnotationRenderer(baseImage: image, scale: 2)
        var state = EditorState()
        // 10..58 pt = 20..116 px, 8 blocks of 12 px.
        state.annotations.append(Annotation(kind: .pixelate, points: [CGPoint(x: 10, y: 10), CGPoint(x: 58, y: 40)], color: .hotPink, thickness: 7))
        let px = Pixels(try XCTUnwrap(renderer.flatten(state)))
        for blockX in 0..<8 {
            let x0 = 20 + blockX * 12
            let c = px[x0, 20]
            for dx in 0..<12 { for dy in 0..<12 { XCTAssertTrue(px[x0 + dx, 20 + dy] == c, "block \(blockX) not uniform") } }
        }
        XCTAssertFalse(px[20, 20] == px[32, 20], "neighbouring blocks differ on a gradient")
        // Outside the region keeps the original gradient.
        let original = Pixels(image)
        XCTAssertTrue(px[150, 5] == original[150, 5])
        XCTAssertEqual(Pixelator.blockSize(forScale: 2), 12)
        XCTAssertEqual(Pixelator.blockSize(forScale: 1), 6)
    }

    func testPixelateFollowsTheShape() throws {
        let renderer = AnnotationRenderer(baseImage: makeImage(width: 200, height: 100, gradient: true), scale: 1)
        var a = Annotation(kind: .pixelate, points: [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 30)], color: .hotPink, thickness: 7)
        var state = EditorState(); state.annotations = [a]
        let first = Pixels(try XCTUnwrap(renderer.flatten(state)))
        a = a.offsetBy(dx: 100, dy: 0); state.annotations = [a]
        let moved = Pixels(try XCTUnwrap(renderer.flatten(state)))
        XCTAssertFalse(first[101, 1] == moved[101, 1])
        XCTAssertTrue(moved[101, 1] == moved[104, 4])
    }

    func testPNGCarriesDPIForScale() throws {
        let data = try XCTUnwrap(PNGWriter.data(for: makeImage(width: 20, height: 10), scale: 2))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((props[kCGImagePropertyDPIWidth] as? NSNumber)?.intValue, 144)
        XCTAssertEqual((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 20)
    }
}
