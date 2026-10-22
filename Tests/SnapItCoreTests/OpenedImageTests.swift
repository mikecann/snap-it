import XCTest
@testable import SnapItCore

final class OpenedImageTests: XCTestCase {
    func testScaleFromNameWinsOverDPI() {
        XCTAssertEqual(OpenedImage.scale(fileName: "Screenshot 2026-10-22 at 1.02.03 PM@2x.png", dpi: 72), 2)
        XCTAssertEqual(OpenedImage.scale(fileName: "icon@3x.png", dpi: 144), 3)
        XCTAssertEqual(OpenedImage.scale(fileName: "Shot (2)@2x.jpg", dpi: nil), 2)
    }

    func testScaleFromDPI() {
        XCTAssertEqual(OpenedImage.scale(fileName: "photo.jpg", dpi: 144), 2)
        XCTAssertEqual(OpenedImage.scale(fileName: "photo.png", dpi: 216), 3)
        XCTAssertEqual(OpenedImage.scale(fileName: "photo.png", dpi: 72), 1)
        XCTAssertEqual(OpenedImage.scale(fileName: "photo.png", dpi: 300), 4)
        XCTAssertEqual(OpenedImage.scale(fileName: "photo.png", dpi: nil), 1)
        XCTAssertEqual(OpenedImage.scale(fileName: "me@home.png", dpi: nil), 1)
    }

    func testPNGSavesInPlace() {
        let png = URL(fileURLWithPath: "/tmp/shots/Shot@2x.png")
        XCTAssertEqual(OpenedImage.saveURL(for: png) { _ in true }, png)
        let upper = URL(fileURLWithPath: "/tmp/shots/SHOT.PNG")
        XCTAssertEqual(OpenedImage.saveURL(for: upper) { _ in true }, upper)
    }

    func testOtherFormatsSaveToASiblingPNG() {
        let jpeg = URL(fileURLWithPath: "/tmp/shots/photo.jpg")
        XCTAssertEqual(OpenedImage.saveURL(for: jpeg) { _ in false }.path, "/tmp/shots/photo.png")
        let taken: Set<String> = ["/tmp/shots/photo.png", "/tmp/shots/photo (2).png"]
        XCTAssertEqual(OpenedImage.saveURL(for: jpeg) { taken.contains($0.path) }.path, "/tmp/shots/photo (3).png")
        let retina = URL(fileURLWithPath: "/tmp/shots/mock@2x.heic")
        XCTAssertEqual(OpenedImage.saveURL(for: retina) { $0.path == "/tmp/shots/mock@2x.png" }.path, "/tmp/shots/mock (2)@2x.png")
    }

    func testLoadReadsScaleFromDPI() throws {
        let image = try XCTUnwrap(solidImage(width: 40, height: 20))
        let data = try XCTUnwrap(PNGWriter.data(for: image, scale: 2))
        let loaded = try XCTUnwrap(OpenedImage.load(data: data, fileName: "plain.png"))
        XCTAssertEqual(loaded.scale, 2)
        XCTAssertEqual(loaded.image.width, 40)
        XCTAssertEqual(loaded.image.height, 20)
        XCTAssertEqual(OpenedImage.load(data: data, fileName: "plain@3x.png")?.scale, 3)
        XCTAssertNil(OpenedImage.load(data: Data("hello".utf8), fileName: "notes.png"))
    }

    private func solidImage(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
