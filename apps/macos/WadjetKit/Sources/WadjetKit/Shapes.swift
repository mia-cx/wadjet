import CoreGraphics

/// A Shapes variant with its option; drawn inside an Annotation's rect.
public enum ShapeKind: Codable, Equatable, Sendable {
    case rectangle(cornerRadius: CGFloat)
    case ellipse
    case polygon(sides: Int)
    case star(points: Int, innerRatio: CGFloat)

    public var variant: ShapeVariant {
        switch self {
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .polygon: .polygon
        case .star: .star
        }
    }

    /// the closed outline inside `rect` (y up), untransformed
    public func path(in rect: CGRect) -> CGPath {
        switch self {
        case let .rectangle(cornerRadius):
            // CGPath(roundedRect:) traps past half the shorter side
            let r = min(max(0, cornerRadius), min(rect.width, rect.height) / 2)
            return r == 0 ? CGPath(rect: rect, transform: nil)
                : CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        case .ellipse:
            return CGPath(ellipseIn: rect, transform: nil)
        case let .polygon(sides):
            return outline(count: max(3, sides), in: rect) { _ in 1 }
        case let .star(points, innerRatio):
            let ratio = min(0.95, max(0.05, innerRatio))
            return outline(count: 2 * max(3, points), in: rect) { $0 % 2 == 1 ? ratio : 1 }
        }
    }

    /// `count` vertices on the ellipse inscribed in `rect`, the first at the
    /// top (angle π/2); `radius` scales each toward the centre — a star's
    /// inner vertices. On a square rect the polygon is regular.
    private func outline(count: Int, in rect: CGRect, radius: (Int) -> CGFloat) -> CGPath {
        let p = CGMutablePath()
        for k in 0..<count {
            let a = CGFloat.pi / 2 + 2 * .pi * CGFloat(k) / CGFloat(count)
            let r = radius(k)
            let pt = CGPoint(x: rect.midX + rect.width / 2 * r * cos(a),
                             y: rect.midY + rect.height / 2 * r * sin(a))
            if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}

/// one slider in the Shapes menu, read and set field by field so a
/// multi-selection can show "Mixed" for it alone and a change keeps every
/// shape's other options
public enum ShapeOption: CaseIterable, Sendable {
    case cornerRadius, sides, points, innerRatio
}

extension ShapeKind {
    /// the option's value, nil for a variant that lacks it
    public func value(of o: ShapeOption) -> Double? {
        switch (self, o) {
        case let (.rectangle(r), .cornerRadius): Double(r)
        case let (.polygon(n), .sides): Double(n)
        case let (.star(n, _), .points): Double(n)
        case let (.star(_, r), .innerRatio): Double(r)
        default: nil
        }
    }

    /// the option set to `v`, everything else kept; a variant that lacks it is unchanged
    public func setting(_ o: ShapeOption, to v: Double) -> ShapeKind {
        switch (self, o) {
        case (.rectangle, .cornerRadius): .rectangle(cornerRadius: CGFloat(v))
        case (.polygon, .sides): .polygon(sides: Int(v.rounded()))
        case let (.star(_, r), .points): .star(points: Int(v.rounded()), innerRatio: r)
        case let (.star(n, _), .innerRatio): .star(points: n, innerRatio: CGFloat(v))
        default: self
        }
    }
}

/// the Shapes Tool's variants, named as config.json's `markup.tools` keys
public enum ShapeVariant: String, Codable, CaseIterable, Sendable {
    case rectangle, ellipse, polygon, star
    public var title: String { rawValue.capitalized }
    public var symbol: String {
        switch self {
        case .rectangle: "rectangle"; case .ellipse: "circle"
        case .polygon: "pentagon"; case .star: "star"
        }
    }
    public var variant: ToolVariant { ToolVariant(id: rawValue, title: title, symbol: symbol) }
    /// the shape a variant draws before the user changes its option
    public var defaultShape: ShapeKind {
        switch self {
        case .rectangle: .rectangle(cornerRadius: 0)
        case .ellipse: .ellipse
        case .polygon: .polygon(sides: 5)
        case .star: .star(points: 5, innerRatio: 0.4)
        }
    }
}

extension CGRect {
    /// the rect a drag from `start` to `end` draws. `square` (Shift) takes the
    /// longer side on both axes, keeping the drag's direction; `fromCentre`
    /// (Option) centres it on `start`.
    public init(dragFrom start: CGPoint, to end: CGPoint, square: Bool, fromCentre: Bool) {
        var dx = end.x - start.x, dy = end.y - start.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = (dx < 0 ? -side : side) // the sign of a 0 counts as +
            dy = (dy < 0 ? -side : side)
        }
        self = fromCentre
            ? CGRect(x: start.x - abs(dx), y: start.y - abs(dy),
                     width: 2 * abs(dx), height: 2 * abs(dy))
            : CGRect(x: start.x + min(dx, 0), y: start.y + min(dy, 0),
                     width: abs(dx), height: abs(dy))
    }
}
