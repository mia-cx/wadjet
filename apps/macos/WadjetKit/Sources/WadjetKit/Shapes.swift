import CoreGraphics

/// A Shapes variant with its option; drawn inside an Annotation's rect.
public enum ShapeKind: Equatable, Sendable {
    case rectangle(cornerRadius: CGFloat)
    case ellipse
    /// `cornerRadius` rounds every vertex alike, as on a rectangle
    case polygon(sides: Int, cornerRadius: CGFloat = 0)
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
        case let .polygon(sides, cornerRadius):
            let r = min(max(0, cornerRadius), maxCornerRadius(in: rect))
            guard r > 0 else { return outline(count: max(3, sides), in: rect) { _ in 1 } }
            return Self.rounded(vertices(count: max(3, sides), in: rect) { _ in 1 }, radius: r)
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
        p.addLines(between: vertices(count: count, in: rect, radius: radius))
        p.closeSubpath()
        return p
    }

    func vertices(count: Int, in rect: CGRect, radius: (Int) -> CGFloat) -> [CGPoint] {
        (0..<count).map { k in
            let a = CGFloat.pi / 2 + 2 * .pi * CGFloat(k) / CGFloat(count)
            let r = radius(k)
            return CGPoint(x: rect.midX + rect.width / 2 * r * cos(a),
                           y: rect.midY + rect.height / 2 * r * sin(a))
        }
    }

    /// the closed outline through `v` with every corner filleted at `radius`,
    /// which the caller keeps within maxCornerRadius
    private static func rounded(_ v: [CGPoint], radius: CGFloat) -> CGPath {
        let p = CGMutablePath(), n = v.count
        p.move(to: CGPoint(x: (v[n - 1].x + v[0].x) / 2, y: (v[n - 1].y + v[0].y) / 2))
        for k in 0..<n { p.addArc(tangent1End: v[k], tangent2End: v[(k + 1) % n], radius: radius) }
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
        case let (.rectangle(r), .cornerRadius), let (.polygon(_, r), .cornerRadius): Double(r)
        case let (.polygon(n, _), .sides): Double(n)
        case let (.star(n, _), .points): Double(n)
        case let (.star(_, r), .innerRatio): Double(r)
        default: nil
        }
    }

    /// the option set to `v`, everything else kept; a variant that lacks it is unchanged
    public func setting(_ o: ShapeOption, to v: Double) -> ShapeKind {
        switch (self, o) {
        case (.rectangle, .cornerRadius): .rectangle(cornerRadius: CGFloat(v))
        case let (.polygon(_, r), .sides): .polygon(sides: Int(v.rounded()), cornerRadius: r)
        case let (.polygon(n, _), .cornerRadius): .polygon(sides: n, cornerRadius: CGFloat(v))
        case let (.star(_, r), .points): .star(points: Int(v.rounded()), innerRatio: r)
        case let (.star(n, _), .innerRatio): .star(points: n, innerRatio: CGFloat(v))
        default: self
        }
    }
}

extension ShapeOption {
    /// the values the menu's slider and the on-canvas widgets allow; a corner
    /// widget may round past the slider's end, up to what the shape holds
    public var range: ClosedRange<Double> {
        switch self {
        case .cornerRadius: 0...40
        case .sides, .points: 3...12
        case .innerRatio: 0.2...0.8
        }
    }
}

/// the synthesized form, `{"polygon":{"sides":5}}`, with a polygon's
/// `cornerRadius` written only when it rounds, so older files still read
extension ShapeKind: Codable {
    private enum Keys: String, CodingKey { case rectangle, ellipse, polygon, star }
    private enum Fields: String, CodingKey { case cornerRadius, sides, points, innerRatio }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let key = c.allKeys.first, c.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath,
                                                    debugDescription: "a shape names exactly one variant"))
        }
        let f = try c.nestedContainer(keyedBy: Fields.self, forKey: key)
        switch key {
        case .rectangle: self = .rectangle(cornerRadius: try f.decode(CGFloat.self, forKey: .cornerRadius))
        case .ellipse: self = .ellipse
        case .polygon:
            self = .polygon(sides: try f.decode(Int.self, forKey: .sides),
                            cornerRadius: try f.decodeIfPresent(CGFloat.self, forKey: .cornerRadius) ?? 0)
        case .star:
            self = .star(points: try f.decode(Int.self, forKey: .points),
                         innerRatio: try f.decode(CGFloat.self, forKey: .innerRatio))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .rectangle(r):
            var f = c.nestedContainer(keyedBy: Fields.self, forKey: .rectangle)
            try f.encode(r, forKey: .cornerRadius)
        case .ellipse:
            _ = c.nestedContainer(keyedBy: Fields.self, forKey: .ellipse)
        case let .polygon(n, r):
            var f = c.nestedContainer(keyedBy: Fields.self, forKey: .polygon)
            try f.encode(n, forKey: .sides)
            if r != 0 { try f.encode(r, forKey: .cornerRadius) }
        case let .star(n, r):
            var f = c.nestedContainer(keyedBy: Fields.self, forKey: .star)
            try f.encode(n, forKey: .points)
            try f.encode(r, forKey: .innerRatio)
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
