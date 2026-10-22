import CoreGraphics
import Foundation

public enum Tool: String, CaseIterable, Sendable {
    case arrow, rectangle, filledRectangle, ellipse, line, text, pen, highlighter, pixelate, crop

    public var shortcut: Character {
        switch self {
        case .arrow: "a"
        case .rectangle: "r"
        case .filledRectangle: "f"
        case .ellipse: "o"
        case .line: "l"
        case .text: "t"
        case .pen: "p"
        case .highlighter: "h"
        case .pixelate: "x"
        case .crop: "c"
        }
    }

    public var title: String {
        switch self {
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .filledRectangle: "Filled Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .text: "Text"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .pixelate: "Pixelate"
        case .crop: "Crop"
        }
    }

    public init?(shortcut: Character) {
        guard let tool = Tool.allCases.first(where: { $0.shortcut == Character(shortcut.lowercased()) }) else { return nil }
        self = tool
    }

    /// The annotation this tool draws; crop draws none.
    public var shapeKind: ShapeKind? {
        switch self {
        case .arrow: .arrow
        case .rectangle: .rectangle
        case .filledRectangle: .filledRectangle
        case .ellipse: .ellipse
        case .line: .line
        case .text: .text
        case .pen: .pen
        case .highlighter: .highlighter
        case .pixelate: .pixelate
        case .crop: nil
        }
    }
}

public enum ShapeKind: String, Sendable {
    case arrow, line, rectangle, filledRectangle, ellipse, pen, highlighter, pixelate, text

    /// Shapes defined by two corners of a rectangle.
    public var isBoxed: Bool { [.rectangle, .filledRectangle, .ellipse, .pixelate].contains(self) }
    public var isFreehand: Bool { self == .pen || self == .highlighter }
}

public struct RGBAColor: Equatable, Hashable, Sendable {
    public var red, green, blue, alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    /// Mike's CleanShot colour, RGB(255, 0, 165).
    public static let hotPink = RGBAColor(red: 1, green: 0, blue: 165.0 / 255.0)

    public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    public func withAlpha(_ a: CGFloat) -> RGBAColor { RGBAColor(red: red, green: green, blue: blue, alpha: a) }
}

/// One live annotation, in image points (top-left origin, y down).
/// Arrows and lines use `[tail, head]`, boxed shapes two opposite corners, freehand strokes every point,
/// and text the top-left corner of its box.
public struct Annotation: Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: ShapeKind
    public var points: [CGPoint]
    public var color: RGBAColor
    public var thickness: CGFloat
    public var text: String
    public var fontSize: CGFloat

    public init(id: UUID = UUID(), kind: ShapeKind, points: [CGPoint], color: RGBAColor, thickness: CGFloat, text: String = "", fontSize: CGFloat = 35) {
        self.id = id; self.kind = kind; self.points = points; self.color = color
        self.thickness = thickness; self.text = text; self.fontSize = fontSize
    }

    public var rect: CGRect {
        guard let first = points.first else { return .zero }
        return normalizedRect(first, points.last ?? first)
    }

    public var textBounds: CGRect {
        CGRect(origin: points.first ?? .zero, size: TextStyle.size(of: text, fontSize: fontSize))
    }

    /// Drawn too small to keep after a drag.
    public var isDegenerate: Bool {
        switch kind {
        case .arrow, .line: return points.count < 2 || pointDistance(points[0], points[1]) < 2
        case .rectangle, .filledRectangle, .ellipse, .pixelate: return rect.width < 2 || rect.height < 2
        case .pen, .highlighter:
            guard points.count >= 2 else { return true }
            let box = points.dropFirst().reduce(CGRect(origin: points[0], size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
            return max(box.width, box.height) < 1
        case .text: return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Endpoints for arrows and lines, corners (top-left, top-right, bottom-right, bottom-left) for boxed shapes.
    public var handles: [CGPoint] {
        switch kind {
        case .arrow, .line: return points.count == 2 ? points : []
        case .rectangle, .filledRectangle, .ellipse, .pixelate:
            let r = rect
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        case .pen, .highlighter, .text: return []
        }
    }

    /// The point that stays put while handle `index` is dragged: the other endpoint, or the opposite corner.
    /// Capture it once when a drag starts, so crossing over it doesn't swap which corner is fixed.
    public func anchor(forHandle index: Int) -> CGPoint? {
        let points = handles
        guard points.indices.contains(index) else { return nil }
        switch kind {
        case .arrow, .line: return points[1 - index]
        default: return points[(index + 2) % 4]
        }
    }

    /// Moves handle `index` to `p`. Pass the `anchor` captured at drag start for boxed shapes.
    public func movingHandle(_ index: Int, to p: CGPoint, anchor: CGPoint? = nil) -> Annotation {
        var copy = self
        switch kind {
        case .arrow, .line:
            guard points.indices.contains(index) else { return self }
            copy.points[index] = p
        case .rectangle, .filledRectangle, .ellipse, .pixelate:
            guard let fixed = anchor ?? self.anchor(forHandle: index) else { return self }
            copy.points = [fixed, p]
        case .pen, .highlighter, .text: break
        }
        return copy
    }

    public func offsetBy(dx: CGFloat, dy: CGFloat) -> Annotation {
        var copy = self
        copy.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return copy
    }

    /// Outline used for the selection box, including the stroke.
    public var bounds: CGRect {
        switch kind {
        case .text: return textBounds
        case .filledRectangle, .pixelate: return rect
        case .arrow: return ShapePaths.arrowPath(from: points[0], to: points[points.count - 1], thickness: thickness).boundingBoxOfPath
        default:
            let width = kind == .highlighter ? thickness * ShapePaths.highlighterWidthFactor : thickness
            return ShapePaths.strokePath(for: self).boundingBoxOfPath.insetBy(dx: -width / 2, dy: -width / 2)
        }
    }

    public func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case .text: return textBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case .filledRectangle, .pixelate: return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        case .arrow:
            guard points.count == 2 else { return false }
            if ShapePaths.arrowPath(from: points[0], to: points[1], thickness: thickness).contains(p) { return true }
            return ShapePaths.distance(from: p, toSegment: points[0], points[1]) <= thickness / 2 + tolerance
        default:
            let width = (kind == .highlighter ? thickness * ShapePaths.highlighterWidthFactor : thickness) + tolerance * 2
            return ShapePaths.strokePath(for: self).copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(p)
        }
    }
}
