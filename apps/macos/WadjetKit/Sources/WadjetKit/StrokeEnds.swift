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

    /// the outward unit direction at the path's p3 end: the chord from the
    /// point `reach` of arc length back along the stroke to the tip (or from
    /// the path's start when it's shorter). A freehand stroke ends in 1-pt
    /// integer steps, so the last segment's own tangent snaps to an axis; the
    /// chord follows the stroke the arrowhead covers. A straight Line's chord
    /// is its own direction. Falls back to the tangent when the chord is degenerate
    static func endOutward(_ segments: [Segment], reach: CGFloat) -> CGPoint {
        guard let last = segments.last else { return CGPoint(x: 1, y: 0) }
        return chordOutward(segments, reach: reach) ?? last.endOutward
    }

    /// the outward unit direction at the path's p0 end — endOutward's mirror
    static func startOutward(_ segments: [Segment], reach: CGFloat) -> CGPoint {
        guard let first = segments.first else { return CGPoint(x: -1, y: 0) }
        return chordOutward(reversed(segments), reach: reach) ?? first.startOutward
    }

    /// endOutward's chord, or nil when it's too short to aim
    private static func chordOutward(_ segments: [Segment], reach: CGFloat) -> CGPoint? {
        guard let tip = segments.last?.p3 else { return nil }
        var walked: CGFloat = 0, here = tip, back = tip
        outer: for s in segments.reversed() {
            let steps = s.straight ? 1 : 16
            for i in stride(from: steps - 1, through: 0, by: -1) {
                let p = s.point(at: CGFloat(i) / CGFloat(steps))
                let step = hypot(p.x - here.x, p.y - here.y)
                if walked + step >= reach, step > 0 {
                    let f = (reach - walked) / step
                    back = CGPoint(x: here.x + (p.x - here.x) * f, y: here.y + (p.y - here.y) * f)
                    break outer
                }
                walked += step
                here = p
                back = p
            }
        }
        return Segment.unit(CGPoint(x: tip.x - back.x, y: tip.y - back.y))
    }

    /// the same stroke run from p3 back to p0
    static func reversed(_ segments: [Segment]) -> [Segment] {
        segments.reversed().map { Segment(p0: $0.p3, c1: $0.c2, c2: $0.c1, p3: $0.p0, straight: $0.straight) }
    }

    /// `segments` with the end within `d` points of the path's p3 tip cut
    /// off, across as many segments as that reaches — a freehand stroke's
    /// last segment is often shorter than `d`. Walking back from the tip, it
    /// cuts at whichever comes first: the first point `d` from the tip (the
    /// crossing nearest the tip, when the curve doubles back), or `reach` of
    /// arc length. The cap keeps the stem joined to a head aimed by
    /// endOutward(_:reach:): that chord's far end sits on the head's axis, so
    /// a stroke that curls inside the d-circle can't lose its curl and leave
    /// the head floating. A path that ends before either collapses to its start
    static func trimmedEnd(_ segments: [Segment], by d: CGFloat, within reach: CGFloat) -> [Segment] {
        guard let tip = segments.last?.p3 else { return segments }
        func far(_ s: Segment, _ t: CGFloat) -> CGFloat {
            let v = s.point(at: t)
            return hypot(v.x - tip.x, v.y - tip.y)
        }
        var walked: CGFloat = 0
        for i in segments.indices.reversed() {
            let s = segments[i]
            var near: CGFloat = 1, here = s.p3
            for k in stride(from: 63, through: 0, by: -1) {
                let t = CGFloat(k) / 64, p = s.point(at: t)
                let step = hypot(p.x - here.x, p.y - here.y)
                var cut: CGFloat?
                if far(s, t) >= d {
                    // bisect the step for the radial crossing
                    var lo = t, hi = near
                    for _ in 0..<40 {
                        let mid = (lo + hi) / 2
                        if far(s, mid) > d { lo = mid } else { hi = mid }
                    }
                    cut = hi
                }
                if walked + step >= reach, step > 0 {
                    // the arc cap, if it lands nearer the tip than the crossing
                    let ta = near - (near - t) * (reach - walked) / step
                    cut = max(cut ?? ta, ta)
                }
                if let cut {
                    var piece = s.split(at: cut).0
                    piece.straight = s.straight
                    return Array(segments[..<i]) + [piece]
                }
                walked += step
                here = p
                near = t
            }
        }
        let a = segments[0].p0
        return [Segment(p0: a, c1: a, c2: a, p3: a, straight: true)]
    }

    /// `segments` with the end near the path's p0 cut off — trimmedEnd's mirror
    static func trimmedStart(_ segments: [Segment], by d: CGFloat, within reach: CGFloat) -> [Segment] {
        reversed(trimmedEnd(reversed(segments), by: d, within: reach))
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
}
