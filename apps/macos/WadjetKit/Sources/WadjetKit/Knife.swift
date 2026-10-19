import CoreGraphics
import Foundation

extension LayerStack {
    /// splits every visible, unlocked Annotation the cut segment a→b crosses
    /// into its pieces, each in the original's layer position, pieces in path
    /// order; true when anything was cut
    @discardableResult
    public mutating func cut(from a: CGPoint, to b: CGPoint) -> Bool {
        var out: [Annotation] = []
        var didCut = false
        for annotation in annotations {
            if !annotation.hidden && !annotation.locked,
               let pieces = annotation.cut(from: a, to: b) {
                out.append(contentsOf: pieces)
                didCut = true
            } else {
                out.append(annotation)
            }
        }
        annotations = out
        return didCut
    }
}

/// where the cut meets one geometry segment: `t` within the segment, `u` =
/// seg + t along the whole path, `s` the parameter along the cut a→b
private struct KnifeCrossing {
    var seg: Int
    var t: CGFloat
    var s: CGFloat
    var point: CGPoint
    var u: CGFloat { CGFloat(seg) + t }
}

/// a shape outline walked into nodes: move starts it, line adds a corner,
/// quad elevates to cubic (each handle sits ⅔ toward the control), cubic
/// maps straight to handles, closeSubpath closes. An outline that returns
/// to its start point (ellipse, rounded rect) folds the last node into the
/// first.
extension PathData {
    init(outline path: CGPath) {
        var nodes: [PathNode] = []
        var closed = false
        path.applyWithBlock { el in
            let p = el.pointee.points
            switch el.pointee.type {
            case .moveToPoint, .addLineToPoint:
                nodes.append(PathNode(anchor: p[0]))
            case .addQuadCurveToPoint:
                let from = nodes.last?.anchor ?? .zero, c = p[0], to = p[1]
                if !nodes.isEmpty {
                    nodes[nodes.count - 1].handleOut = CGPoint(x: from.x + (c.x - from.x) * 2 / 3,
                                                               y: from.y + (c.y - from.y) * 2 / 3)
                }
                nodes.append(PathNode(anchor: to,
                                      handleIn: CGPoint(x: to.x + (c.x - to.x) * 2 / 3,
                                                        y: to.y + (c.y - to.y) * 2 / 3)))
            case .addCurveToPoint:
                if !nodes.isEmpty { nodes[nodes.count - 1].handleOut = p[0] }
                nodes.append(PathNode(anchor: p[2], handleIn: p[1]))
            case .closeSubpath:
                closed = true
            @unknown default:
                break
            }
        }
        if nodes.count > 1, let first = nodes.first, let last = nodes.last,
           hypot(last.anchor.x - first.anchor.x, last.anchor.y - first.anchor.y) < 1e-9 {
            nodes[0].handleIn = last.handleIn
            nodes.removeLast()
        }
        self.init(nodes: nodes, closed: closed)
    }
}

/// the Knife's geometry: crossing solve, de Casteljau splits, loop tracing —
/// all in an Annotation's untransformed geometry space
private enum Knife {
    static func cross(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.y - a.y * b.x }
    static func lerp(_ p: CGPoint, _ q: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)
    }
    static func near(_ p: CGPoint, _ q: CGPoint, _ tol: CGFloat) -> Bool {
        hypot(p.x - q.x, p.y - q.y) <= tol
    }

    /// every cut-segment/geometry-segment intersection, sorted by the path
    /// parameter u; only hits whose position s along a→b is inside the cut's
    /// span count. A cut through a shared node reports on both segments —
    /// dedupe by point keeps one.
    static func crossings(_ segs: [Segment], from a: CGPoint, to b: CGPoint,
                          tol: CGFloat) -> [KnifeCrossing] {
        let d = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let d2 = d.x * d.x + d.y * d.y
        func sParam(_ p: CGPoint) -> CGFloat {
            ((p.x - a.x) * d.x + (p.y - a.y) * d.y) / d2
        }
        var out: [KnifeCrossing] = []
        for (i, s) in segs.enumerated() {
            let hits: [(t: CGFloat, point: CGPoint)] = s.straight
                ? straight(s, from: a, to: b).map { [($0, lerp(s.p0, s.p3, $0))] } ?? []
                : cubic(s, from: a, to: b)
            for (t, p) in hits where sParam(p) >= 0 && sParam(p) <= 1 {
                out.append(KnifeCrossing(seg: i, t: t, s: sParam(p), point: p))
            }
        }
        out.sort { $0.u < $1.u }
        return out.reduce(into: []) { kept, x in
            if let last = kept.last, near(x.point, last.point, tol) { return }
            kept.append(x)
        }
    }

    /// crossings() dedupes neighbours in u order; on a closed loop a hit on
    /// the first node also reports at u≈count, so the loop ends meet too
    static func dedupeClosed(_ crossings: inout [KnifeCrossing], tol: CGFloat) {
        if let first = crossings.first, let last = crossings.last,
           crossings.count > 1, near(first.point, last.point, tol) {
            crossings.removeLast()
        }
    }

    /// t along the straight segment where a→b crosses it; nil when parallel
    /// or the meeting point falls outside either segment
    static func straight(_ s: Segment, from a: CGPoint, to b: CGPoint) -> CGFloat? {
        let d = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let e = CGPoint(x: s.p3.x - s.p0.x, y: s.p3.y - s.p0.y)
        let den = cross(d, e)
        guard abs(den) > 1e-12 else { return nil }
        let r = CGPoint(x: s.p0.x - a.x, y: s.p0.y - a.y)
        let t = cross(r, d) / den
        let su = cross(r, e) / den
        guard t >= 0, t <= 1, su >= 0, su <= 1 else { return nil }
        return t
    }

    /// the cubic's zero crossings of the signed distance to a→b: the control
    /// points' distances are the distance curve's Bernstein coefficients;
    /// [0,1] splits into monotone runs at the derivative's real roots, and a
    /// run whose ends change sign bisects to its root. An exact zero at a run
    /// boundary counts only when the sign changes across it — a tangent
    /// touch isn't a cut.
    static func cubic(_ s: Segment, from a: CGPoint, to b: CGPoint) -> [(t: CGFloat, point: CGPoint)] {
        let d = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let n = CGPoint(x: d.y, y: -d.x)
        func h(_ p: CGPoint) -> CGFloat { (p.x - a.x) * n.x + (p.y - a.y) * n.y }
        let h0 = h(s.p0), h1 = h(s.c1), h2 = h(s.c2), h3 = h(s.p3)
        func value(_ t: CGFloat) -> CGFloat {
            let u = 1 - t
            return h0 * u * u * u + 3 * h1 * u * u * t + 3 * h2 * u * t * t + h3 * t * t * t
        }
        let eps = 1e-9 * max(1, hypot(n.x, n.y))
        var ends = [CGFloat(0), 1]
        // the derivative's coefficients in power basis: 3a₃t² + 2a₂t + a₁
        ends += quadraticRoots(3 * (-h0 + 3 * h1 - 3 * h2 + h3),
                               2 * (3 * h0 - 6 * h1 + 3 * h2),
                               -3 * h0 + 3 * h1).filter { $0 > 0 && $0 < 1 }
        ends.sort()
        var roots: [CGFloat] = []
        for i in 0..<ends.count - 1 {
            let t0 = ends[i], t1 = ends[i + 1]
            let v0 = value(t0), v1 = value(t1)
            if abs(v0) <= eps {
                // an endpoint zero counts only across a sign change — at the
                // segment's very start there's no earlier side, so it counts
                if i == 0 || value(ends[i - 1]) * v1 < 0 { roots.append(t0) }
                continue
            }
            guard v0 * v1 < 0 else { continue }
            var lo = t0, hi = t1, lv = v0
            for _ in 0..<60 {
                let mid = (lo + hi) / 2, mv = value(mid)
                if abs(mv) <= eps { lo = mid; hi = mid; break }
                if (mv < 0) == (lv < 0) { lo = mid; lv = mv } else { hi = mid }
            }
            roots.append((lo + hi) / 2)
        }
        if abs(value(1)) <= eps { roots.append(1) }
        return roots.map { ($0, eval(s, $0)) }
    }

    /// real roots of a·x² + b·x + c
    static func quadraticRoots(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat) -> [CGFloat] {
        guard abs(a) > 1e-15 else {
            guard abs(b) > 1e-15 else { return [] }
            return [-c / b]
        }
        let disc = b * b - 4 * a * c
        guard disc >= 0 else { return [] }
        let r = disc.squareRoot()
        return [(-b + r) / (2 * a), (-b - r) / (2 * a)]
    }

    /// the segment's point at t
    static func eval(_ s: Segment, _ t: CGFloat) -> CGPoint {
        guard !s.straight else { return lerp(s.p0, s.p3, t) }
        let a = lerp(s.p0, s.c1, t), b = lerp(s.c1, s.c2, t), c = lerp(s.c2, s.p3, t)
        return lerp(lerp(a, b, t), lerp(b, c, t), t)
    }

    /// de Casteljau at t: (the part before t, the part after) — a straight
    /// segment stays straight
    static func split(_ s: Segment, at t: CGFloat) -> (Segment, Segment) {
        if s.straight {
            let m = lerp(s.p0, s.p3, t)
            return (Segment(p0: s.p0, c1: s.p0, c2: m, p3: m, straight: true),
                    Segment(p0: m, c1: m, c2: s.p3, p3: s.p3, straight: true))
        }
        let a = lerp(s.p0, s.c1, t), b = lerp(s.c1, s.c2, t), c = lerp(s.c2, s.p3, t)
        let d = lerp(a, b, t), e = lerp(b, c, t), f = lerp(d, e, t)
        return (Segment(p0: s.p0, c1: a, c2: d, p3: f, straight: false),
                Segment(p0: f, c1: e, c2: c, p3: s.p3, straight: false))
    }

    /// every segment split at its crossings — sequential, with t
    /// renormalised over the remainder — plus each crossing's boundary index
    /// into `sub`, found by point so a hit on an original node lands too.
    /// Boundary indices for a closed loop can reach `sub.count` — the wrap
    /// node, counted again at the loop's end.
    static func subdivide(_ segs: [Segment], _ crossings: [KnifeCrossing],
                          tol: CGFloat, closed: Bool)
        -> (sub: [Segment], at: [(index: Int, crossing: Int)]) {
        var sub: [Segment] = []
        for (i, seg) in segs.enumerated() {
            var remaining = seg, consumed: CGFloat = 0
            for x in crossings where x.seg == i {
                let tp = (x.t - consumed) / (1 - consumed)
                guard tp > 1e-9, tp < 1 - 1e-9 else { continue }
                let (l, r) = split(remaining, at: tp)
                sub.append(l)
                remaining = r
                consumed = x.t
            }
            sub.append(remaining)
        }
        var at: [(index: Int, crossing: Int)] = []
        var cur = 1
        for (xi, x) in crossings.enumerated() {
            if closed, x.u < 1, near(sub[0].p0, x.point, tol) {
                at.append((0, xi))
                continue
            }
            var found = -1
            for j in cur..<sub.count where near(sub[j].p0, x.point, tol) {
                found = j
                break
            }
            if found < 0, closed, x.u > CGFloat(segs.count) - 1,
               near(sub[0].p0, x.point, tol) {
                found = sub.count // the wrap node, at the loop's end
            }
            if found >= 0 {
                at.append((found, xi))
                cur = found + 1
            }
        }
        return (sub, at)
    }

    /// a segment chain's nodes: each segment's inner controls become the
    /// handles of the nodes around it — nil for a straight segment or a
    /// handle on its anchor, so Pen corners stay corners. A closed chain's
    /// last anchor repeats the first, so it drops (the closing segment
    /// covers it).
    static func nodes(for segs: [Segment], closed: Bool) -> [PathNode] {
        guard let first = segs.first else { return [] }
        var nodes = [PathNode(anchor: first.p0)]
        for s in segs { nodes.append(PathNode(anchor: s.p3)) }
        if closed { nodes.removeLast() }
        for (i, s) in segs.enumerated() where !s.straight {
            let into = closed ? (i + 1) % nodes.count : i + 1
            if s.c1 != nodes[i].anchor { nodes[i].handleOut = s.c1 }
            if s.c2 != nodes[into].anchor { nodes[into].handleIn = s.c2 }
        }
        return nodes
    }

    /// a Brush stroke's samples split at the crossing points, in path order:
    /// each point projects onto the raw polyline searching forward from the
    /// previous split (keeps it monotone), and the projection ends one raw
    /// piece and opens the next
    static func splitRaw(_ raw: [CGPoint], at points: [CGPoint]) -> [[CGPoint]] {
        var pieces: [[CGPoint]] = []
        var start = 0, cursor = 0
        var cursorT: CGFloat = 0
        var head: CGPoint? = nil
        for p in points {
            var best = (i: cursor, t: cursorT, d2: CGFloat.greatestFiniteMagnitude)
            for j in cursor..<raw.count - 1 {
                let a = raw[j], b = raw[j + 1]
                let e = CGPoint(x: b.x - a.x, y: b.y - a.y)
                let l2 = e.x * e.x + e.y * e.y
                var t = l2 > 0 ? ((p.x - a.x) * e.x + (p.y - a.y) * e.y) / l2 : 0
                t = min(1, max(j == cursor ? cursorT : 0, t))
                let q = CGPoint(x: a.x + e.x * t, y: a.y + e.y * t)
                let d2 = (p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y)
                if d2 < best.d2 { best = (j, t, d2) }
            }
            let proj = lerp(raw[best.i], raw[min(best.i + 1, raw.count - 1)], best.t)
            var piece = head.map { [$0] } ?? []
            piece += raw[start...best.i]
            piece.append(proj)
            pieces.append(piece)
            head = proj
            start = best.i + 1
            cursor = best.i
            cursorT = best.t
        }
        var last = head.map { [$0] } ?? []
        last += raw[start...]
        pieces.append(last)
        return pieces
    }
}

extension Annotation {
    /// the pieces a Knife cut a→b leaves, nil when it doesn't split this one —
    /// only Lines, paths and Shapes cut; everything else (Censor, counter,
    /// Magnify, and any later kind) is never cut
    public func cut(from a: CGPoint, to b: CGPoint) -> [Annotation]? {
        let data: PathData
        let straightLine: Bool
        switch kind {
        case let .line(start, end, .none):
            data = PathData(nodes: [PathNode(anchor: start), PathNode(anchor: end)])
            straightLine = true
        case .line:
            // a bent Line is one elevated quadratic — nodes carry its handles
            guard let s = kind.segments.first else { return nil }
            data = PathData(nodes: [PathNode(anchor: s.p0, handleOut: s.c1),
                                    PathNode(anchor: s.p3, handleIn: s.c2)])
            straightLine = false
        case let .path(d):
            data = d
            straightLine = false
        case let .shape(sk, rect):
            data = PathData(outline: sk.path(in: rect))
            straightLine = false
        default:
            return nil
        }
        guard data.nodes.count >= 2 else { return nil }
        // cut in untransformed geometry space
        let inv = affineTransform.inverted()
        let ga = a.applying(inv), gb = b.applying(inv)
        guard ga != gb else { return nil }
        let scale = max(1, kind.bounds.width, kind.bounds.height,
                        hypot(gb.x - ga.x, gb.y - ga.y))
        let tol = 1e-6 * scale
        let segs = AnnotationKind.path(data).segments
        var crossings = Knife.crossings(segs, from: ga, to: gb, tol: tol)
        if !data.closed {
            // crossings at the very start or end leave only degenerate pieces
            let ends = [data.nodes[0].anchor, data.nodes[data.nodes.count - 1].anchor]
            crossings.removeAll { x in
                x.u < 1e-9 || x.u > CGFloat(segs.count) - 1e-9
                    || ends.contains { Knife.near(x.point, $0, tol) }
            }
            guard !crossings.isEmpty else { return nil }
            return finishPieces(openPieces(segs, crossings, data: data,
                                           straightLine: straightLine, tol: tol),
                                ends: true)
        }
        Knife.dedupeClosed(&crossings, tol: tol)
        guard let datas = closedPieces(segs, crossings, tol: tol) else { return nil }
        return finishPieces(datas.map { (kind: .path($0), first: false, last: false) },
                            ends: false)
    }

    /// open geometry: chains between consecutive crossings — a straight
    /// Line's pieces stay Lines, anything else becomes open paths; a Brush
    /// stroke's raw samples split to match. Each entry carries whether it's
    /// the path's first or last piece, for the ends.
    private func openPieces(_ segs: [Segment], _ crossings: [KnifeCrossing],
                            data: PathData, straightLine: Bool, tol: CGFloat)
        -> [(kind: AnnotationKind, first: Bool, last: Bool)] {
        let (sub, at) = Knife.subdivide(segs, crossings, tol: tol, closed: false)
        var ranges: [Range<Int>] = []
        var prev = 0
        for b in at where b.index > prev {
            ranges.append(prev..<b.index)
            prev = b.index
        }
        if prev < sub.count { ranges.append(prev..<sub.count) }
        let rawPieces = data.rawPoints.map {
            Knife.splitRaw($0, at: at.map { crossings[$0.crossing].point })
        }
        return ranges.enumerated().map { i, r in
            let chain = Array(sub[r])
            let kind: AnnotationKind = straightLine
                ? .line(start: chain[0].p0, end: chain[chain.count - 1].p3)
                : .path(PathData(nodes: Knife.nodes(for: chain, closed: false),
                                 rawPoints: rawPieces.map { $0[i] },
                                 smoothing: data.smoothing))
            return (kind, i == 0, i == ranges.count - 1)
        }
    }

    /// closed geometry: consecutive crossings along the cut pair into chords
    /// when their midpoint is inside; crossings in no chord drop out. The
    /// loop splits into arcs at the chord crossings, and each piece traces
    /// arc → chord → arc until it comes back to its start — every arc used
    /// once. Returns nil when no chord formed.
    private func closedPieces(_ segs: [Segment], _ crossings: [KnifeCrossing],
                              tol: CGFloat) -> [PathData]? {
        let geo = PathGeometry.path(segments: segs, closed: true)
        let byS = crossings.indices.sorted { crossings[$0].s < crossings[$1].s }
        var inChord = Set<Int>()
        var partners: [Int: Int] = [:]
        for k in 0..<byS.count - 1 {
            let i = byS[k], j = byS[k + 1]
            // a crossing pairs once — skipping claimed ones keeps `partners`
            // symmetric when an odd hit leaves a crossing unpaired
            guard !inChord.contains(i), !inChord.contains(j) else { continue }
            let mid = CGPoint(x: (crossings[i].point.x + crossings[j].point.x) / 2,
                              y: (crossings[i].point.y + crossings[j].point.y) / 2)
            guard geo.contains(mid, using: .evenOdd) else { continue }
            inChord.insert(i); inChord.insert(j)
            partners[i] = j; partners[j] = i
        }
        guard !inChord.isEmpty else { return nil }
        let chorded = crossings.enumerated().filter { inChord.contains($0.offset) }
        var remap: [Int: Int] = [:]
        for (new, e) in chorded.enumerated() { remap[e.offset] = new }
        // partner(chorded index) = chorded index
        var partner: [Int: Int] = [:]
        for (i, j) in partners {
            if let m = remap[i], let n = remap[j] { partner[m] = n }
        }
        let cd = chorded.map(\.element)
        let (sub, at) = Knife.subdivide(segs, cd, tol: tol, closed: true)
        let n = sub.count, k = at.count
        /// the arc index whose start boundary is each chorded crossing's
        var startArc: [Int: Int] = [:]
        for (m, e) in at.enumerated() { startArc[e.crossing] = m }
        var used = Set<Int>()
        var out: [PathData] = []
        for m in 0..<k where !used.contains(m) {
            var chain: [Segment] = []
            var cur = m
            while !used.contains(cur) {
                used.insert(cur)
                let start = at[cur].index
                let next = (cur + 1) % k
                let end = cur + 1 < k ? at[next].index : at[0].index + n
                for i in start..<end { chain.append(sub[i % n]) }
                // jump along the chord to the partner crossing and keep
                // tracing the arc that starts there
                let endX = cd[at[next].crossing]
                guard let px = partner[at[next].crossing], let arc = startArc[px]
                else { break }
                chain.append(Segment(p0: endX.point, c1: endX.point,
                                     c2: cd[px].point, p3: cd[px].point, straight: true))
                cur = arc
            }
            if !chain.isEmpty {
                out.append(PathData(nodes: Knife.nodes(for: chain, closed: true),
                                    closed: true))
            }
        }
        return out
    }

    /// each piece as an Annotation: a new id, the same style (ends adjusted
    /// for open pieces), the same transform — pinned by one geometry point,
    /// since the transform pivots on the bounds centre and cutting moved it.
    /// Pieces whose bounds degenerate drop.
    private func finishPieces(_ pieces: [(kind: AnnotationKind, first: Bool, last: Bool)],
                              ends: Bool) -> [Annotation]? {
        let out = pieces.compactMap { entry -> Annotation? in
            var p = Annotation(kind: entry.kind, style: style, transform: transform)
            if ends {
                p.style.tail = entry.first ? style.tail : .none
                p.style.head = entry.last ? style.head : .none
            }
            let b = p.kind.bounds
            guard b.width >= 1e-6 || b.height >= 1e-6 else { return nil }
            guard let q = p.kind.points.first else { return nil }
            let was = q.applying(affineTransform), now = q.applying(p.affineTransform)
            return p.moved(by: CGVector(dx: was.x - now.x, dy: was.y - now.y))
        }
        // a single survivor isn't a cut — it's a re-kinded copy with a new id
        return out.count >= 2 ? out : nil
    }
}
