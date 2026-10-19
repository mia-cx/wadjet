import CoreGraphics
import Foundation

/// what sits at one end of an open stroke; sized from the stroke width
public enum LineEnd: String, Codable, CaseIterable, Sendable {
    case none, openArrow, filledArrow, dot, bar
}

/// the stroke's middle; the pattern scales with the stroke width
public enum LineDash: String, Codable, CaseIterable, Sendable {
    case solid, dashed, dotted
    /// dash lengths for a round-capped stroke `width` wide (nil = solid): dashed shows 3w dashes with 2w gaps ([2w, 3w]), dotted shows w-wide dots w apart ([0, 2w])
    public func pattern(width: CGFloat) -> [CGFloat]? {
        switch self {
        case .solid: nil
        case .dashed: [2 * width, 3 * width]
        case .dotted: [0, 2 * width]
        }
    }
}

extension PathGeometry {
    /// an arrowhead's length from tip to base, at stroke width `w`
    static func headLength(width w: CGFloat) -> CGFloat { 3 * w + 6 }

    /// the filled outline `end` contributes at `tip`: `u` the outward unit
    /// direction (away from the stroke), `n` its left-hand normal
    static func endMark(_ end: LineEnd, at tip: CGPoint, u: CGPoint, n: CGPoint,
                        width w: CGFloat) -> CGPath {
        func pt(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
            CGPoint(x: tip.x + a * u.x + b * n.x, y: tip.y + a * u.y + b * n.y)
        }
        let p = CGMutablePath()
        switch end {
        case .none: break
        case .filledArrow:
            let l = headLength(width: w)
            p.move(to: tip)
            p.addLine(to: pt(-l, l * tan(.pi / 6)))
            p.addLine(to: pt(-l, -l * tan(.pi / 6)))
            p.closeSubpath()
        case .openArrow:
            let l = headLength(width: w), c = l * cos(.pi / 6), s = l * sin(.pi / 6)
            let arms = CGMutablePath()
            arms.move(to: pt(-c, s))
            arms.addLine(to: tip)
            arms.addLine(to: pt(-c, -s))
            return arms.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10)
        case .dot:
            p.addEllipse(in: CGRect(x: tip.x - w - 2, y: tip.y - w - 2,
                                    width: 2 * (w + 2), height: 2 * (w + 2)))
        case .bar:
            let h = 1.5 * w + 4
            let stem = CGMutablePath()
            stem.move(to: pt(0, h))
            stem.addLine(to: pt(0, -h))
            return stem.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10)
        }
        return p
    }

    /// `segments` with `d` points cut off the last segment's p3 end
    static func trimmedEnd(_ segments: [Segment], by d: CGFloat) -> [Segment] {
        var segs = segments
        guard let last = segs.last else { return segs }
        segs[segs.count - 1] = last.straight ? last.clippedEnd(by: d) : last.splitEnd(by: d)
        return segs
    }

    /// `segments` with `d` points cut off the first segment's p0 end
    static func trimmedStart(_ segments: [Segment], by d: CGFloat) -> [Segment] {
        var segs = segments
        guard let first = segs.first else { return segs }
        segs[0] = first.straight ? first.clippedStart(by: d) : first.splitStart(by: d)
        return segs
    }
}

extension Segment {
    /// unit vector `v`, or nil when it's too short to aim
    static func unit(_ v: CGPoint) -> CGPoint? {
        let l = hypot(v.x, v.y)
        guard l > 1e-9 else { return nil }
        return CGPoint(x: v.x / l, y: v.y / l)
    }

    /// outward direction at the p3 end (falls back to p0 for a degenerate curve)
    var endOutward: CGPoint {
        Self.unit(CGPoint(x: p3.x - c2.x, y: p3.y - c2.y))
            ?? Self.unit(CGPoint(x: p3.x - c1.x, y: p3.y - c1.y))
            ?? Self.unit(CGPoint(x: p3.x - p0.x, y: p3.y - p0.y))
            ?? CGPoint(x: 1, y: 0)
    }

    /// outward direction at the p0 end
    var startOutward: CGPoint {
        Self.unit(CGPoint(x: p0.x - c1.x, y: p0.y - c1.y))
            ?? Self.unit(CGPoint(x: p0.x - c2.x, y: p0.y - c2.y))
            ?? Self.unit(CGPoint(x: p0.x - p3.x, y: p0.y - p3.y))
            ?? CGPoint(x: -1, y: 0)
    }

    func point(at t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p3.x,
                       y: u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p3.y)
    }

    /// de Casteljau: the pieces either side of `t`
    func split(at t: CGFloat) -> (Segment, Segment) {
        func lerp(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        let a = lerp(p0, c1), b = lerp(c1, c2), c = lerp(c2, p3)
        let d = lerp(a, b), e = lerp(b, c), f = lerp(d, e)
        return (Segment(p0: p0, c1: a, c2: d, p3: f, straight: false),
                Segment(p0: f, c1: e, c2: c, p3: p3, straight: false))
    }

    /// the same straight segment with p3 pulled `d` towards p0 (clamped at p0)
    func clippedEnd(by d: CGFloat) -> Segment {
        let u = endOutward, len = hypot(p3.x - p0.x, p3.y - p0.y)
        let p = CGPoint(x: p3.x - u.x * min(d, len), y: p3.y - u.y * min(d, len))
        return Segment(p0: p0, c1: p0, c2: p, p3: p, straight: true)
    }

    /// the same straight segment with p0 pushed `d` towards p3 (clamped at p3)
    func clippedStart(by d: CGFloat) -> Segment {
        let u = startOutward, len = hypot(p3.x - p0.x, p3.y - p0.y)
        let p = CGPoint(x: p0.x - u.x * min(d, len), y: p0.y - u.y * min(d, len))
        return Segment(p0: p, c1: p, c2: p3, p3: p3, straight: true)
    }

    /// the [0, t] piece where |B(t) − p3| ≈ d — the tail end trimmed off
    func splitEnd(by d: CGFloat) -> Segment {
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            let v = point(at: mid)
            if hypot(v.x - p3.x, v.y - p3.y) > d { lo = mid } else { hi = mid }
        }
        return split(at: hi).0
    }

    /// the [t, 1] piece where |B(t) − p0| ≈ d — the head end trimmed off
    func splitStart(by d: CGFloat) -> Segment {
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let mid = (lo + hi) / 2
            let v = point(at: mid)
            if hypot(v.x - p0.x, v.y - p0.y) < d { lo = mid } else { hi = mid }
        }
        return split(at: lo).1
    }
}
