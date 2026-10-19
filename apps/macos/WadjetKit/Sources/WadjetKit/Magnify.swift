import CoreGraphics
import Foundation

/// the magnifier's silhouette; `path` is its outline inside `rect` (y up)
public enum MagnifierShape: String, Codable, CaseIterable, Sendable {
    case superellipse, circle, rectangle
    /// the exponent of the default shape's |x/a|^n + |y/b|^n = 1
    public static let superellipseExponent: CGFloat = 4
    /// the n in the normalised radius form ((|x|/a)^n + (|y|/b)^n)^(1/n);
    /// the rectangle's is infinity, the L∞ limit = the max form
    var exponent: CGFloat {
        switch self {
        case .rectangle: .infinity
        case .circle: 2
        case .superellipse: Self.superellipseExponent
        }
    }
    public func path(in rect: CGRect) -> CGPath {
        switch self {
        case .rectangle:
            return CGPath(rect: rect, transform: nil)
        case .circle:
            return CGPath(ellipseIn: rect, transform: nil)
        case .superellipse:
            // |x/a|^n + |y/b|^n = 1 as a closed polygon
            let a = rect.width / 2, b = rect.height / 2, n = Self.superellipseExponent
            let p = CGMutablePath()
            for k in 0..<128 {
                let t = 2 * .pi * CGFloat(k) / 128, c = cos(t), s = sin(t)
                let pt = CGPoint(x: rect.midX + a * copysign(pow(abs(c), 2 / n), c),
                                 y: rect.midY + b * copysign(pow(abs(s), 2 / n), s))
                if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
            return p
        }
    }
}

/// how the source pixels scale into the magnifier
public enum MagnifyScaling: String, Codable, CaseIterable, Sendable {
    case nearestNeighbour, lanczos
}

/// the non-geometry choices: the Magnify Tool's defaults live at
/// `markup.tools.magnify.magnifier`, each Magnify carries its own copy
public struct MagnifierOptions: Codable, Equatable, Sendable {
    public var shape: MagnifierShape = .superellipse
    /// the line joining the source outline and the magnifier edge
    public var leader = true
    /// a Liquid Glass rim over the magnifier's edge
    public var glass = true
    /// a stroke around the shape; nil = no border
    public var border: RGBAColour? = nil
    public var scaling: MagnifyScaling = .nearestNeighbour
    public init(shape: MagnifierShape = .superellipse, leader: Bool = true, glass: Bool = true,
                border: RGBAColour? = nil, scaling: MagnifyScaling = .nearestNeighbour) {
        self.shape = shape
        self.leader = leader
        self.glass = glass
        self.border = border
        self.scaling = scaling
    }
    /// every key decodes to its default when absent — a saved `{}` is the stock magnifier
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shape = try c.decodeIfPresent(MagnifierShape.self, forKey: .shape) ?? .superellipse
        leader = try c.decodeIfPresent(Bool.self, forKey: .leader) ?? true
        glass = try c.decodeIfPresent(Bool.self, forKey: .glass) ?? true
        border = try c.decodeIfPresent(RGBAColour.self, forKey: .border)
        scaling = try c.decodeIfPresent(MagnifyScaling.self, forKey: .scaling) ?? .nearestNeighbour
    }
}

/// A Magnify: `source` is the outlined area the tool colour marks, `frame` the
/// magnifier box that shows it enlarged. One flat JSON object — the geometry
/// keys and `options`' keys share the object.
public struct Magnifier: Codable, Equatable, Sendable {
    /// the outlined area, global points
    public var source: CGRect
    /// the magnifier's box, global points
    public var frame: CGRect
    /// nil = auto from the source's size; scroll on the magnifier sets it
    public var zoom: CGFloat?
    public var options: MagnifierOptions
    public init(source: CGRect, frame: CGRect, zoom: CGFloat? = nil, options: MagnifierOptions) {
        self.source = source
        self.frame = frame
        self.zoom = zoom
        self.options = options
    }

    enum CodingKeys: String, CodingKey { case source, frame, zoom }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeRect(forKey: .source)
        frame = try c.decodeRect(forKey: .frame)
        zoom = try c.decodeIfPresent(CGFloat.self, forKey: .zoom)
        options = try MagnifierOptions(from: decoder)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeRect(source, forKey: .source)
        try c.encodeRect(frame, forKey: .frame)
        try c.encodeIfPresent(zoom, forKey: .zoom)
        try options.encode(to: encoder)
    }

    /// the zoom the magnifier draws at: the override when set, else auto
    public var effectiveZoom: CGFloat { zoom ?? MagnifyZoom.auto(for: source.size) }
    /// the global rect the magnifier shows — what gets sampled
    public var viewport: CGRect {
        let size = CGSize(width: frame.width / effectiveZoom, height: frame.height / effectiveZoom)
        return CGRect(x: source.midX - size.width / 2, y: source.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
    /// the leader line, edge to edge along the centre line: where the ray from
    /// the source's centre exits the source rect, and where the ray back exits
    /// the magnifier's shape. nil when the centres coincide or the magnifier
    /// and the source overlap along the ray
    public var leader: (start: CGPoint, end: CGPoint)? {
        let sc = CGPoint(x: source.midX, y: source.midY)
        let fc = CGPoint(x: frame.midX, y: frame.midY)
        let d = CGVector(dx: fc.x - sc.x, dy: fc.y - sc.y)
        guard d.dx != 0 || d.dy != 0 else { return nil }
        // the fraction along d where the ray exits a box or a shape centred at t
        func exit(_ a: CGFloat, _ b: CGFloat, _ n: CGFloat) -> CGFloat {
            let x = abs(d.dx) / a, y = abs(d.dy) / b
            if n.isInfinite { return 1 / max(x, y) }
            return 1 / pow(pow(x, n) + pow(y, n), 1 / n)
        }
        let start = exit(source.width / 2, source.height / 2, .infinity)
        let end = exit(frame.width / 2, frame.height / 2, options.shape.exponent)
        guard start.isFinite, end.isFinite, start < 1 - end else { return nil }
        return (CGPoint(x: sc.x + d.dx * start, y: sc.y + d.dy * start),
                CGPoint(x: sc.x + d.dx * (1 - end), y: sc.y + d.dy * (1 - end)))
    }

    /// a freshly drawn Magnify's placement: sized from the source at auto zoom,
    /// put on the side opposite the display edge nearest the source's centre,
    /// then kept inside the display's margin
    public static func placed(source: CGRect, options: MagnifierOptions, on display: CGRect) -> Magnifier {
        let minSide: CGFloat = 64, maxSide: CGFloat = 320, gap: CGFloat = 24, margin: CGFloat = 8
        let z = MagnifyZoom.auto(for: source.size)
        var size = CGSize(width: min(max(source.width * z, minSide), maxSide),
                          height: min(max(source.height * z, minSide), maxSide))
        if options.shape == .circle {
            let side = max(size.width, size.height)
            size = CGSize(width: side, height: side)
        }
        let c = CGPoint(x: source.midX, y: source.midY)
        // the nearest display edge; the magnifier goes on its opposite side
        let edges = [(d: c.x - display.minX, x: source.maxX + gap, y: c.y - size.height / 2),
                     (d: display.maxX - c.x, x: source.minX - gap - size.width, y: c.y - size.height / 2),
                     (d: c.y - display.minY, x: c.x - size.width / 2, y: source.maxY + gap),
                     (d: display.maxY - c.y, x: c.x - size.width / 2, y: source.minY - gap - size.height)]
        let pick = edges.min { $0.d < $1.d } ?? edges[0]
        var frame = CGRect(x: pick.x, y: pick.y, width: size.width, height: size.height)
        let area = display.insetBy(dx: margin, dy: margin)
        // too big for the margin pins to its min edge
        frame.origin.x = frame.width <= area.width
            ? min(max(frame.minX, area.minX), area.maxX - frame.width) : area.minX
        frame.origin.y = frame.height <= area.height
            ? min(max(frame.minY, area.minY), area.maxY - frame.height) : area.minY
        return Magnifier(source: source, frame: frame, zoom: nil, options: options)
    }
}

/// Magnify's zoom maths: auto follows the source size, `stepped` moves on the
/// quarter-step grid the scroll gesture counts in
public enum MagnifyZoom {
    public static let range: ClosedRange<CGFloat> = 1.5...8
    public static let step: CGFloat = 0.25
    /// 4× for a source 64 pt or under on its longer side, 2× at 256 pt or over, linear between
    public static func auto(for size: CGSize) -> CGFloat {
        let s = max(size.width, size.height)
        if s <= 64 { return 4 }
        if s >= 256 { return 2 }
        return 4 - 2 * (s - 64) / (256 - 64)
    }
    /// `zoom` rounded to the step grid plus `steps` more steps, clamped to `range`
    public static func stepped(_ zoom: CGFloat, by steps: Int) -> CGFloat {
        let z = (zoom / step).rounded() * step + CGFloat(steps) * step
        return min(max(z, range.lowerBound), range.upperBound)
    }
}
