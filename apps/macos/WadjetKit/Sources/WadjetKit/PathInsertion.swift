import CoreGraphics
import Foundation

extension AnnotationKind {
    /// Lines and paths are made of nodes a press can add to
    public var insertsNodes: Bool {
        switch self {
        case .line, .path: true
        default: false
        }
    }
}

extension Annotation {
    /// a new node on the stroke where it passes nearest `point` (screen
    /// coordinates), and its index. The segment under it splits by de
    /// Casteljau, so the curve keeps its shape. A Line turns into an open
    /// path with the same ends; a Brush stroke drops its samples, because a
    /// refit would discard the node. nil for kinds without nodes, or when the
    /// nearest spot is an existing node.
    public func insertingNode(near point: CGPoint) -> (annotation: Annotation, node: Int)? {
        var data: PathData
        switch kind {
        case let .line(start, end, .none):
            data = PathData(nodes: [PathNode(anchor: start), PathNode(anchor: end)])
        case .line:
            // a bent Line is one elevated quadratic: its controls become handles
            guard let s = kind.segments.first else { return nil }
            data = PathData(nodes: [PathNode(anchor: s.p0, handleOut: s.c1),
                                    PathNode(anchor: s.p3, handleIn: s.c2)])
        case let .path(d):
            data = d
            data.rawPoints = nil
            data.smoothing = nil
        default:
            return nil
        }
        guard data.nodes.count >= 2 else { return nil }
        // work in untransformed geometry space; the transform stays as it is
        let q = point.applying(affineTransform.inverted())
        let segs = AnnotationKind.path(data).segments
        guard let (i, t) = Self.nearest(on: segs, to: q) else { return nil }
        // a spot on an existing node adds nothing
        let tEnd: CGFloat = 1e-3
        guard t > tEnd, t < 1 - tEnd else { return nil }
        let j = (i + 1) % data.nodes.count
        let seg = segs[i]
        let new: PathNode
        if seg.straight {
            new = PathNode(anchor: CGPoint(x: seg.p0.x + (seg.p3.x - seg.p0.x) * t,
                                           y: seg.p0.y + (seg.p3.y - seg.p0.y) * t))
        } else {
            let (l, r) = seg.split(at: t)
            func handle(_ h: CGPoint, _ anchor: CGPoint) -> CGPoint? { h == anchor ? nil : h }
            data.nodes[i].handleOut = handle(l.c1, l.p0)
            data.nodes[j].handleIn = handle(r.c2, r.p3)
            new = PathNode(anchor: l.p3, handleIn: handle(l.c2, l.p3), handleOut: handle(r.c1, r.p0))
        }
        data.nodes.insert(new, at: i + 1)
        var a = self
        a.kind = .path(data)
        // the bounds centre is the transform's pivot: pin the first node on
        // screen in case the new kind's bounds came out a hair different
        let pin = data.nodes[0].anchor
        let was = pin.applying(affineTransform), now = pin.applying(a.affineTransform)
        return (a.moved(by: CGVector(dx: was.x - now.x, dy: was.y - now.y)), i + 1)
    }

    /// the segment index and parameter nearest `p`: a coarse scan, then a
    /// golden-section refine around the best sample
    static func nearest(on segs: [Segment], to p: CGPoint) -> (Int, CGFloat)? {
        func d2(_ s: Segment, _ t: CGFloat) -> CGFloat {
            let v = s.straight
                ? CGPoint(x: s.p0.x + (s.p3.x - s.p0.x) * t, y: s.p0.y + (s.p3.y - s.p0.y) * t)
                : s.point(at: t)
            return (v.x - p.x) * (v.x - p.x) + (v.y - p.y) * (v.y - p.y)
        }
        let steps = 64
        var best: (i: Int, t: CGFloat, d: CGFloat)?
        for (i, s) in segs.enumerated() {
            for k in 0...steps {
                let t = CGFloat(k) / CGFloat(steps), d = d2(s, t)
                if best == nil || d < best!.d { best = (i, t, d) }
            }
        }
        guard let b = best else { return nil }
        let s = segs[b.i], g = (sqrt(5) - 1) / 2
        var lo = max(0, b.t - 1 / CGFloat(steps)), hi = min(1, b.t + 1 / CGFloat(steps))
        for _ in 0..<40 {
            let m1 = hi - g * (hi - lo), m2 = lo + g * (hi - lo)
            if d2(s, m1) < d2(s, m2) { hi = m2 } else { lo = m1 }
        }
        return (b.i, (lo + hi) / 2)
    }
}
