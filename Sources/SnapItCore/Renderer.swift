import AppKit
import CoreGraphics

/// Draws the base image and annotations in image points (top-left origin, y down).
/// The editor canvas and export both use it, so what you see is what gets saved.
public final class AnnotationRenderer {
    public let baseImage: CGImage
    public let scale: CGFloat
    public let imageSize: CGSize
    private var pixelateCache: [String: CGImage] = [:]

    public init(baseImage: CGImage, scale: CGFloat) {
        self.baseImage = baseImage
        self.scale = scale
        imageSize = CGSize(width: CGFloat(baseImage.width) / scale, height: CGFloat(baseImage.height) / scale)
    }

    public var imageBounds: CGRect { CGRect(origin: .zero, size: imageSize) }

    /// Draws a CGImage upright into `rect` of a y-down context.
    static func drawImage(_ image: CGImage, in rect: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    public func drawBase(in ctx: CGContext) {
        Self.drawImage(baseImage, in: imageBounds, context: ctx)
    }

    public func draw(_ state: EditorState, in ctx: CGContext, skipping hidden: UUID? = nil) {
        for a in state.annotations where a.id != hidden { draw(a, in: ctx) }
    }

    public func draw(_ a: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(a.color.cgColor)
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch a.kind {
        case .arrow:
            guard a.points.count == 2 else { return }
            ctx.addPath(ShapePaths.arrowPath(from: a.points[0], to: a.points[1], thickness: a.thickness))
            ctx.fillPath()
        case .line, .rectangle, .ellipse, .pen:
            ctx.setLineWidth(a.thickness)
            ctx.addPath(ShapePaths.strokePath(for: a))
            ctx.strokePath()
        case .filledRectangle:
            ctx.addPath(ShapePaths.strokePath(for: a))
            ctx.fillPath()
        case .highlighter:
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(a.color.withAlpha(a.color.alpha * 0.4).cgColor)
            ctx.setLineWidth(a.thickness * ShapePaths.highlighterWidthFactor)
            ctx.addPath(ShapePaths.strokePath(for: a))
            ctx.strokePath()
        case .pixelate:
            let pixelRect = CGRect(x: a.rect.minX * scale, y: a.rect.minY * scale, width: a.rect.width * scale, height: a.rect.height * scale)
                .integral.intersection(CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height))
            guard !pixelRect.isNull, let blocks = pixelated(pixelRect) else { return }
            ctx.interpolationQuality = .none
            Self.drawImage(blocks, in: CGRect(x: pixelRect.minX / scale, y: pixelRect.minY / scale,
                                              width: pixelRect.width / scale, height: pixelRect.height / scale), context: ctx)
        case .text:
            guard let origin = a.points.first else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSAttributedString(string: a.text, attributes: TextStyle.attributes(color: a.color, fontSize: a.fontSize))
                .draw(with: CGRect(origin: origin, size: TextStyle.size(of: a.text, fontSize: a.fontSize)), options: [.usesLineFragmentOrigin])
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func pixelated(_ pixelRect: CGRect) -> CGImage? {
        let key = "\(pixelRect.minX),\(pixelRect.minY),\(pixelRect.width),\(pixelRect.height)"
        if let cached = pixelateCache[key] { return cached }
        guard let image = Pixelator.pixelated(baseImage, pixelRect: pixelRect, blockSize: Pixelator.blockSize(forScale: scale)) else { return nil }
        if pixelateCache.count > 64 { pixelateCache.removeAll() }
        pixelateCache[key] = image
        return image
    }

    /// The base image with every annotation, cropped, at full pixel resolution.
    public func flatten(_ state: EditorState) -> CGImage? {
        let visible = state.crop ?? imageBounds
        let width = Int((visible.width * scale).rounded()), height = Int((visible.height * scale).rounded())
        guard width > 0, height > 0 else { return nil }
        let space = baseImage.colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -visible.minX, y: -visible.minY)
        ctx.interpolationQuality = .none
        drawBase(in: ctx)
        ctx.interpolationQuality = .high
        draw(state, in: ctx)
        return ctx.makeImage()
    }
}
