import CoreGraphics
import Foundation

/// Wrapping, as Excalidraw's and tldraw's arrows do: a Line's or path's end
/// attached exactly to a spot on an Annotation with an inside keeps that spot
/// while its Line reaches it from outside. Once the target turns the spot
/// away, the end slides round the outline to the side facing the Line's
/// other end, so the Line never runs through the target. The attachment
/// keeps its spot, so turning the target back brings the end back to it.
extension AttachFinder {
    /// how far, in points, the Line from the neighbour to the spot reaches
    /// into the target when the end has slid all the way to the facing side.
    /// Below it the end is partway, so it slides instead of jumping when a
    /// flat edge holding the spot turns away all at once.
    static let wrapDepth: CGFloat = 6

    /// where an end attached exactly to the screen point `spot` on `target`
    /// sits when its Line or path comes from `origin`: `spot` itself while the
    /// segment from `origin` stays outside the target; otherwise on the
    /// outline between `spot` and the facing point, where a Line from
    /// `origin` aimed at the focus (halfway from the target's centre to the
    /// spot, Excalidraw's focus) first meets the outline. The deeper the
    /// segment from `origin` to `spot` reaches inside, the nearer the facing
    /// point, which it reaches at `wrapDepth`. `spot` when `origin` is inside
    /// the target, or the target has no inside.
    public static func exactEnd(at spot: CGPoint, from origin: CGPoint, on target: Annotation) -> CGPoint {
        guard target.kind.hasAttachInterior else { return spot }
        let outline = outline(of: target)
        guard !outline.contains(origin) else { return spot }
        let edges = chords(of: outline)
        let d = depth(from: origin, to: spot, inside: outline, edges: edges)
        guard d > 0 else { return spot }
        let c = centre(of: target), focus = CGPoint(x: (c.x + spot.x) / 2, y: (c.y + spot.y) / 2)
        let facing = outlineCrossing(from: focus, to: origin, outline: outline)
        let x = min(1, d / wrapDepth)
        return along(edges, from: spot, to: facing, x * x * (3 - 2 * x))
    }

    /// how far the segment `a`→`b` reaches inside `outline`: the greatest
    /// distance from the outline of any point on it that lies inside. A
    /// coarse scan, then a golden-section refine around the deepest sample.
    static func depth(from a: CGPoint, to b: CGPoint, inside outline: CGPath, edges: [(CGPoint, CGPoint)]) -> CGFloat {
        func at(_ t: CGFloat) -> CGFloat {
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            guard outline.contains(p) else { return 0 }
            return edges.map { distance(from: p, to: $0) }.min() ?? 0
        }
        let steps = 128
        var best = (t: CGFloat(0), d: CGFloat(0))
        for k in 0...steps {
            let t = CGFloat(k) / CGFloat(steps), d = at(t)
            if d > best.d { best = (t, d) }
        }
        guard best.d > 0 else { return 0 }
        var lo = max(0, best.t - 1 / CGFloat(steps)), hi = min(1, best.t + 1 / CGFloat(steps))
        let g = (sqrt(5) - 1) / 2
        for _ in 0..<30 {
            let m1 = hi - g * (hi - lo), m2 = lo + g * (hi - lo)
            if at(m1) > at(m2) { hi = m2 } else { lo = m1 }
        }
        return max(best.d, at((lo + hi) / 2))
    }

    /// the distance from `p` to the chord `e`
    static func distance(from p: CGPoint, to e: (CGPoint, CGPoint)) -> CGFloat {
        let (a, b) = e, dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy
        let t = l2 == 0 ? 0 : min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return hypot(a.x + t * dx - p.x, a.y + t * dy - p.y)
    }

    /// the point a fraction `w` of the way from `p` to `q` around the
    /// closed outline `edges`, the shorter way round; both are first moved
    /// onto the outline
    static func along(_ edges: [(CGPoint, CGPoint)], from p: CGPoint, to q: CGPoint, _ w: CGFloat) -> CGPoint {
        guard w > 0 else { return p }
        let lengths = edges.map { hypot($0.1.x - $0.0.x, $0.1.y - $0.0.y) }
        let total = lengths.reduce(0, +)
        guard total > 0 else { return q }
        // arc length from the outline's start to the nearest point to `x`
        func arc(_ x: CGPoint) -> CGFloat {
            var best = (s: CGFloat(0), d: CGFloat.infinity), s: CGFloat = 0
            for (i, e) in edges.enumerated() {
                let (a, b) = e, dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy
                let t = l2 == 0 ? 0 : min(1, max(0, ((x.x - a.x) * dx + (x.y - a.y) * dy) / l2))
                let d = hypot(a.x + t * dx - x.x, a.y + t * dy - x.y)
                if d < best.d { best = (s + t * lengths[i], d) }
                s += lengths[i]
            }
            return best.s
        }
        let from = arc(p)
        var delta = (arc(q) - from).truncatingRemainder(dividingBy: total)
        if delta > total / 2 { delta -= total } else if delta < -total / 2 { delta += total }
        var s = (from + w * delta).truncatingRemainder(dividingBy: total)
        if s < 0 { s += total }
        for (i, e) in edges.enumerated() {
            if s <= lengths[i] || i == edges.count - 1 {
                let t = lengths[i] == 0 ? 0 : min(1, s / lengths[i])
                return CGPoint(x: e.0.x + (e.1.x - e.0.x) * t, y: e.0.y + (e.1.y - e.0.y) * t)
            }
            s -= lengths[i]
        }
        return q
    }
}
