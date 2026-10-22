import CoreGraphics

public enum ShapePaths {
    public static let highlighterWidthFactor: CGFloat = 3

    // Arrow proportions, measured from Mike's CleanShot arrows at thickness 7.
    static let headLengthFactor: CGFloat = 4.6
    static let headHalfWidthRatio: CGFloat = 0.58
    static let notchRatio: CGFloat = 0.2
    static let tailHalfFactor: CGFloat = 0.32
    static let shaftHalfFactor: CGFloat = 0.7

    /// A filled, tapered arrow: thin rounded tail, shaft widening to a solid head with a notched back.
    public static func arrowPath(from tail: CGPoint, to head: CGPoint, thickness t: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let length = pointDistance(tail, head)
        guard length > 0.01, t > 0 else { return path }
        let u = CGPoint(x: (head.x - tail.x) / length, y: (head.y - tail.y) / length)
        let n = CGPoint(x: -u.y, y: u.x)
        func at(_ origin: CGPoint, along: CGFloat, across: CGFloat) -> CGPoint {
            let x: CGFloat = origin.x + u.x * along + n.x * across
            let y: CGFloat = origin.y + u.y * along + n.y * across
            return CGPoint(x: x, y: y)
        }
        let fullHead = t * headLengthFactor
        let headLength = min(fullHead, length * 0.6)
        // Short arrows shrink the whole arrow, not just the head.
        let k = max(headLength / fullHead, 0.4)
        let headHalf = headLength * headHalfWidthRatio
        let shaftHalf = min(t * shaftHalfFactor * k, headHalf * 0.6)
        let tailHalf = min(t * tailHalfFactor * k, shaftHalf)
        let barbLeft = at(head, along: -headLength, across: headHalf)
        let barbRight = at(head, along: -headLength, across: -headHalf)
        let notch = at(head, along: -headLength * (1 - notchRatio), across: 0)
        // Where the shaft edge meets the notched back edge of the head.
        let s = 1 - shaftHalf / headHalf
        let shaftLeft = CGPoint(x: barbLeft.x + (notch.x - barbLeft.x) * s, y: barbLeft.y + (notch.y - barbLeft.y) * s)
        let shaftRight = CGPoint(x: barbRight.x + (notch.x - barbRight.x) * s, y: barbRight.y + (notch.y - barbRight.y) * s)

        path.move(to: at(tail, along: 0, across: tailHalf))
        path.addLine(to: shaftLeft)
        path.addLine(to: barbLeft)
        path.addLine(to: head)
        path.addLine(to: barbRight)
        path.addLine(to: shaftRight)
        path.addLine(to: at(tail, along: 0, across: -tailHalf))
        // Round tail cap, swinging behind the tail from the right edge back to the left.
        let steps = 10
        for i in 1..<steps {
            let a = CGFloat.pi * CGFloat(i) / CGFloat(steps)
            path.addLine(to: at(tail, along: -sin(a) * tailHalf, across: -cos(a) * tailHalf))
        }
        path.closeSubpath()
        return path
    }

    public static func cornerRadius(for rect: CGRect, thickness: CGFloat) -> CGFloat {
        min(max(2, thickness * 0.5), rect.width / 2, rect.height / 2)
    }

    /// The centre line that gets stroked for lines, outlines and freehand strokes.
    public static func strokePath(for a: Annotation) -> CGPath {
        let path = CGMutablePath()
        guard let first = a.points.first else { return path }
        switch a.kind {
        case .line, .arrow:
            path.move(to: first)
            path.addLine(to: a.points.last ?? first)
        case .rectangle, .filledRectangle, .pixelate:
            let r = a.rect
            let radius = cornerRadius(for: r, thickness: a.thickness)
            path.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius)
        case .ellipse:
            path.addEllipse(in: a.rect)
        case .pen, .highlighter:
            return smoothPath(a.points)
        case .text:
            path.addRect(a.textBounds)
        }
        return path
    }

    /// Quadratic curves through the midpoints of the input points.
    public static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first)
            return path
        }
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }
        for i in 1..<(points.count - 1) {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// Keeps the length, snapping the angle to 45° steps.
    public static func snap45(from start: CGPoint, to p: CGPoint) -> CGPoint {
        let length = pointDistance(start, p)
        let step = CGFloat.pi / 4
        let angle = (atan2(p.y - start.y, p.x - start.x) / step).rounded() * step
        return CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length)
    }

    /// The opposite corner of a square from `start` towards `p`, using the shorter side.
    public static func squared(from start: CGPoint, to p: CGPoint) -> CGPoint {
        let dx = p.x - start.x, dy = p.y - start.y
        let side = min(abs(dx), abs(dy))
        return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
    }

    public static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return pointDistance(p, a) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return pointDistance(p, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }
}
