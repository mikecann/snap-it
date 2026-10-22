import CoreGraphics

/// Maps between AppKit global screen points (origin bottom-left of the primary display, y up),
/// display-local points (origin top-left of this display, y down) and frozen-image pixels.
public struct DisplayMapping: Equatable, Sendable {
    public var frame: CGRect
    public var pixelSize: CGSize

    public init(frame: CGRect, pixelSize: CGSize) {
        self.frame = frame
        self.pixelSize = pixelSize
    }

    public var scaleX: CGFloat { frame.width > 0 ? pixelSize.width / frame.width : 1 }
    public var scaleY: CGFloat { frame.height > 0 ? pixelSize.height / frame.height : 1 }
    public var scale: CGFloat { scaleX }
    public var localBounds: CGRect { CGRect(origin: .zero, size: frame.size) }

    public func localPoint(fromGlobal p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - frame.minX, y: frame.maxY - p.y)
    }

    public func globalPoint(fromLocal p: CGPoint) -> CGPoint {
        CGPoint(x: p.x + frame.minX, y: frame.maxY - p.y)
    }

    /// Half-open containment so a point on a shared edge belongs to exactly one display.
    public func contains(global p: CGPoint) -> Bool {
        p.x >= frame.minX && p.x < frame.maxX && p.y >= frame.minY && p.y < frame.maxY
    }

    public static func index(containing p: CGPoint, in displays: [DisplayMapping]) -> Int? {
        displays.firstIndex { $0.contains(global: p) }
    }

    public func pixelPoint(fromLocal p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scaleX, y: p.y * scaleY)
    }

    /// Pixel rect (top-left origin) for a local rect, with each edge rounded and clamped to the image.
    public func pixelRect(fromLocal r: CGRect) -> CGRect {
        let minX = min(max((r.minX * scaleX).rounded(), 0), pixelSize.width)
        let minY = min(max((r.minY * scaleY).rounded(), 0), pixelSize.height)
        let maxX = min(max((r.maxX * scaleX).rounded(), 0), pixelSize.width)
        let maxY = min(max((r.maxY * scaleY).rounded(), 0), pixelSize.height)
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 0), height: max(maxY - minY, 0))
    }
}

public enum SelectionMath {
    /// The drag rectangle from `start` to `current`, clamped to `bounds` (the display the drag began on).
    /// With `square`, the shorter side wins so the square stays inside the bounds.
    public static func rect(from start: CGPoint, to current: CGPoint, square: Bool, within bounds: CGRect) -> CGRect {
        let s = clamp(start, to: bounds)
        var c = clamp(current, to: bounds)
        if square {
            let dx = c.x - s.x, dy = c.y - s.y
            let side = min(abs(dx), abs(dy))
            c = CGPoint(x: s.x + (dx < 0 ? -side : side), y: s.y + (dy < 0 ? -side : side))
        }
        return CGRect(x: min(s.x, c.x), y: min(s.y, c.y), width: abs(c.x - s.x), height: abs(c.y - s.y))
    }

    public static func clamp(_ p: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }
}

func pointDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

func normalizedRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
}
