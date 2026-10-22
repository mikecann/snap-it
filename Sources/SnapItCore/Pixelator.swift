import CoreGraphics

public enum Pixelator {
    /// Block size in pixels: 6 pt, so 12 px on a 2x image.
    public static func blockSize(forScale scale: CGFloat) -> Int { max(Int((6 * scale).rounded()), 2) }

    /// A copy of `pixelRect` (top-left origin) where every block-sized square is its average colour.
    /// Blocks are aligned to the rect's origin, so the result follows the shape when it moves.
    public static func pixelated(_ image: CGImage, pixelRect: CGRect, blockSize: Int) -> CGImage? {
        let r = pixelRect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !r.isNull, r.width >= 1, r.height >= 1, let region = image.cropping(to: r) else { return nil }
        let w = Int(r.width), h = Int(r.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(region, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        // CGContext memory is top row first, matching the top-left origin of `pixelRect`.
        for by in stride(from: 0, to: h, by: blockSize) {
            for bx in stride(from: 0, to: w, by: blockSize) {
                let x1 = min(bx + blockSize, w), y1 = min(by + blockSize, h)
                var sum = (0, 0, 0, 0)
                for y in by..<y1 { for x in bx..<x1 {
                    let i = (y * w + x) * 4
                    sum.0 += Int(bytes[i]); sum.1 += Int(bytes[i + 1]); sum.2 += Int(bytes[i + 2]); sum.3 += Int(bytes[i + 3])
                } }
                let count = (x1 - bx) * (y1 - by)
                let avg = [sum.0 / count, sum.1 / count, sum.2 / count, sum.3 / count].map { UInt8($0) }
                for y in by..<y1 { for x in bx..<x1 {
                    let i = (y * w + x) * 4
                    bytes[i] = avg[0]; bytes[i + 1] = avg[1]; bytes[i + 2] = avg[2]; bytes[i + 3] = avg[3]
                } }
            }
        }
        return ctx.makeImage()
    }
}
