import CoreGraphics

public enum CropHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    public func point(in r: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: r.minX, y: r.minY)
        case .top: CGPoint(x: r.midX, y: r.minY)
        case .topRight: CGPoint(x: r.maxX, y: r.minY)
        case .right: CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: CGPoint(x: r.maxX, y: r.maxY)
        case .bottom: CGPoint(x: r.midX, y: r.maxY)
        case .bottomLeft: CGPoint(x: r.minX, y: r.maxY)
        case .left: CGPoint(x: r.minX, y: r.midY)
        }
    }
}

public enum CropMath {
    public static let minimumSize: CGFloat = 4

    /// Moves the edges a handle controls to `p`, clamped to `bounds` and never smaller than `minimumSize`.
    public static func resize(_ r: CGRect, handle: CropHandle, to p: CGPoint, within bounds: CGRect) -> CGRect {
        let p = SelectionMath.clamp(p, to: bounds)
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        switch handle {
        case .topLeft, .left, .bottomLeft: minX = min(p.x, maxX - minimumSize)
        case .topRight, .right, .bottomRight: maxX = max(p.x, minX + minimumSize)
        case .top, .bottom: break
        }
        switch handle {
        case .topLeft, .top, .topRight: minY = min(p.y, maxY - minimumSize)
        case .bottomLeft, .bottom, .bottomRight: maxY = max(p.y, minY + minimumSize)
        case .left, .right: break
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    public static func move(_ r: CGRect, by delta: CGSize, within bounds: CGRect) -> CGRect {
        let x = min(max(r.minX + delta.width, bounds.minX), bounds.maxX - r.width)
        let y = min(max(r.minY + delta.height, bounds.minY), bounds.maxY - r.height)
        return CGRect(x: x, y: y, width: r.width, height: r.height)
    }

    /// Snaps a crop to whole pixels inside the image. Nil means no crop: the full image, or less than a pixel.
    public static func normalized(_ r: CGRect, imageBounds: CGRect, scale: CGFloat) -> CGRect? {
        let clipped = r.standardized.intersection(imageBounds)
        guard !clipped.isNull else { return nil }
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        let minX = snap(clipped.minX), minY = snap(clipped.minY), maxX = snap(clipped.maxX), maxY = snap(clipped.maxY)
        guard maxX - minX >= 1 / scale, maxY - minY >= 1 / scale else { return nil }
        let snapped = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return snapped == imageBounds ? nil : snapped
    }
}
