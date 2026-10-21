import CoreGraphics
import Foundation

/// Live-shape widgets, after Illustrator's (and Affinity's shape handles): a
/// rectangle's and a polygon's corner widgets round every corner at once, a
/// polygon's sides diamond adds or removes sides, a star's inner-radius dot
/// pinches or fattens it. Each drag edits the Shape's option in place, so it
/// stays a live Shape the Shapes menu's sliders read.

extension ShapeKind {
    /// the sharp corners a corner widget rounds, in `rect` (y up): a
    /// rectangle's from the top-left clockwise, a polygon's vertices from the
    /// top; nil for kinds without corner rounding
    public func corners(in rect: CGRect) -> [CGPoint]? {
        switch self {
        case .rectangle:
            [CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
             CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.minY)]
        case let .polygon(sides, _):
            vertices(count: max(3, sides), in: rect) { _ in 1 }
        case .ellipse, .star:
            nil
        }
    }

    /// the rounding radius
    public var cornerRadius: CGFloat? {
        switch self {
        case let .rectangle(r), let .polygon(_, r): r
        case .ellipse, .star: nil
        }
    }

    /// the largest radius every corner holds before two arcs meet on a side
    public func maxCornerRadius(in rect: CGRect) -> CGFloat {
        if case .rectangle = self { return max(0, min(rect.width, rect.height) / 2) }
        guard let v = corners(in: rect) else { return 0 }
        return v.indices.map { Self.corner(v, $0).maxRadius }.min() ?? 0
    }

    /// corner `i` of `v`: the unit bisector pointing inside, sin of half its
    /// interior angle, and the radius that uses up half its shorter side
    static func corner(_ v: [CGPoint], _ i: Int) -> (bisector: CGVector, halfSin: CGFloat, maxRadius: CGFloat) {
        let n = v.count, p = v[i], a = v[(i + n - 1) % n], b = v[(i + 1) % n]
        let la = hypot(a.x - p.x, a.y - p.y), lb = hypot(b.x - p.x, b.y - p.y)
        guard la > 0, lb > 0 else { return (CGVector(dx: 0, dy: 0), 1, 0) }
        let ua = CGVector(dx: (a.x - p.x) / la, dy: (a.y - p.y) / la)
        let ub = CGVector(dx: (b.x - p.x) / lb, dy: (b.y - p.y) / lb)
        let half = acos(min(1, max(-1, ua.dx * ub.dx + ua.dy * ub.dy))) / 2
        let sx = ua.dx + ub.dx, sy = ua.dy + ub.dy, ls = hypot(sx, sy)
        guard ls > 1e-9, half > 1e-9 else { return (CGVector(dx: 0, dy: 0), 1, 0) }
        return (CGVector(dx: sx / ls, dy: sy / ls), sin(half), min(la, lb) / 2 * tan(half))
    }
}

extension SelectionHandle {
    /// a live Shape's widget: a drag edits its option, not its geometry's points
    public var isShapeWidget: Bool {
        switch self {
        case .cornerRadius, .sides, .innerRadius: true
        default: false
        }
    }
}

extension Annotation {
    /// how far a sides drag goes per side added or removed, in points
    public static let sidesStep: CGFloat = 10

    /// the live-shape widgets on screen. A corner widget sits at its corner's
    /// arc centre, at least `inset` of radius in so it never covers the
    /// corner, and hides while the shape is too small to hold it; the sides
    /// diamond rides the bounds' right edge above its middle grip; the star's
    /// inner-radius dot sits on the top point's spoke at the inner radius.
    public func shapeWidgets(inset: CGFloat) -> [(handle: SelectionHandle, at: CGPoint)] {
        guard case let .shape(k, rect) = kind else { return [] }
        let m = affineTransform
        var out: [(handle: SelectionHandle, at: CGPoint)] = []
        if let v = k.corners(in: rect), let r = k.cornerRadius {
            let limit = k.maxCornerRadius(in: rect)
            let o = max(min(max(0, r), limit), inset)
            if o <= limit {
                for i in v.indices {
                    let c = ShapeKind.corner(v, i), d = o / c.halfSin
                    out.append((.cornerRadius(i), CGPoint(x: v[i].x + c.bisector.dx * d,
                                                          y: v[i].y + c.bisector.dy * d).applying(m)))
                }
            }
        }
        switch k {
        case .polygon where rect.height / 4 >= inset:
            out.append((.sides, CGPoint(x: rect.maxX, y: rect.midY + rect.height / 4).applying(m)))
        case let .star(_, ratio) where rect.height / 2 >= inset:
            out.append((.innerRadius, CGPoint(x: rect.midX, y: rect.midY + rect.height / 2 * ratio).applying(m)))
        default:
            break
        }
        return out
    }

    /// a widget drag from the state at drag start: a corner widget's inward
    /// travel along its bisector sets the radius (clamped to what the shape
    /// holds); the sides diamond adds a side per `sidesStep` dragged down,
    /// removes one per step up; the inner-radius dot follows the pointer
    /// along the spoke. Ranges are the menu sliders'. Other handles return self.
    func draggingShapeWidget(_ handle: SelectionHandle, from start: CGPoint, to point: CGPoint) -> Annotation {
        guard case let .shape(k, rect) = kind else { return self }
        let inv = affineTransform.inverted()
        let a = start.applying(inv), b = point.applying(inv)
        var new = self
        switch (handle, k) {
        case let (.cornerRadius(i), _):
            guard let v = k.corners(in: rect), v.indices.contains(i), let r = k.cornerRadius else { return self }
            let c = ShapeKind.corner(v, i), limit = k.maxCornerRadius(in: rect)
            let inward = (b.x - a.x) * c.bisector.dx + (b.y - a.y) * c.bisector.dy
            let radius = min(max(0, min(max(0, r), limit) + inward * c.halfSin), limit)
            new.kind = .shape(k.setting(.cornerRadius, to: Double(radius)), rect: rect)
        case let (.sides, .polygon(n, _)):
            // the screen's down, whatever the shape's rotation
            let steps = Int((-(point.y - start.y) / Self.sidesStep).rounded())
            let range = ShapeOption.sides.range
            new.kind = .shape(k.setting(.sides, to: min(max(Double(n + steps), range.lowerBound), range.upperBound)),
                              rect: rect)
        case let (.innerRadius, .star(_, ratio)):
            guard rect.height > 0 else { return self }
            let range = ShapeOption.innerRatio.range
            let to = Double(ratio + (b.y - a.y) / (rect.height / 2))
            new.kind = .shape(k.setting(.innerRatio, to: min(max(to, range.lowerBound), range.upperBound)),
                              rect: rect)
        default:
            return self
        }
        return new
    }
}
