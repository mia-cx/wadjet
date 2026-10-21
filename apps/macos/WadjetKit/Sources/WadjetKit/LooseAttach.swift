import CoreGraphics
import Foundation

/// Loose attaching, tldraw's imprecise binding: a Line's or path's end dropped
/// inside another Annotation, away from its spots, aims at that Annotation's
/// centre and stops where it meets the outline, whatever the target does.
extension AttachFinder {
    /// the point a loosely attached end aims at: a Magnify's magnifier
    /// centre, every other kind's frame centre (its rotation pivot)
    public static func centre(of a: Annotation) -> CGPoint {
        if case let .magnify(m) = a.kind { return CGPoint(x: m.frame.midX, y: m.frame.midY) }
        return a.position(of: .frame(CGPoint(x: 0.5, y: 0.5))) ?? .zero
    }

    /// where an end loosely attached to `target` sits when its Line or path
    /// comes from `origin`: on the line from the target's centre to `origin`,
    /// at the last crossing of the target's outline before `origin`. The
    /// centre itself when `origin` is inside and the line never leaves it.
    public static func looseEnd(from origin: CGPoint, on target: Annotation) -> CGPoint {
        outlineCrossing(from: centre(of: target), to: origin, outline: outline(of: target))
    }

    /// the point on segment `c`→`o` where it last crosses `outline`, nearest
    /// `o`; `c` when it never crosses
    static func outlineCrossing(from c: CGPoint, to o: CGPoint, outline: CGPath) -> CGPoint {
        let r = CGVector(dx: o.x - c.x, dy: o.y - c.y)
        var best: CGFloat?
        for (a, b) in chords(of: outline) {
            let s = CGVector(dx: b.x - a.x, dy: b.y - a.y)
            let den = r.dx * s.dy - r.dy * s.dx
            guard abs(den) > 1e-12 else { continue } // parallel: no single crossing
            let ac = CGVector(dx: a.x - c.x, dy: a.y - c.y)
            let t = (ac.dx * s.dy - ac.dy * s.dx) / den // along c→o
            let u = (ac.dx * r.dy - ac.dy * r.dx) / den // along a→b
            guard (0...1).contains(t), (0...1).contains(u) else { continue }
            if best.map({ t > $0 }) ?? true { best = t }
        }
        guard let t = best else { return c }
        return CGPoint(x: c.x + t * r.dx, y: c.y + t * r.dy)
    }

    /// `path` as straight chords, each curve flattened into 24
    static func chords(of path: CGPath) -> [(CGPoint, CGPoint)] {
        var out: [(CGPoint, CGPoint)] = [], cur = CGPoint.zero, start = CGPoint.zero
        func curve(_ pts: [CGPoint]) {
            // a quadratic or cubic from `cur` through its controls
            let all = [cur] + pts
            var prev = cur
            for k in 1...24 {
                let t = CGFloat(k) / 24
                var level = all
                while level.count > 1 {
                    level = zip(level, level.dropFirst()).map {
                        CGPoint(x: $0.x + ($1.x - $0.x) * t, y: $0.y + ($1.y - $0.y) * t)
                    }
                }
                out.append((prev, level[0]))
                prev = level[0]
            }
        }
        path.applyWithBlock { e in
            let el = e.pointee
            switch el.type {
            case .moveToPoint: cur = el.points[0]; start = cur
            case .addLineToPoint: out.append((cur, el.points[0])); cur = el.points[0]
            case .addQuadCurveToPoint: curve([el.points[0], el.points[1]]); cur = el.points[1]
            case .addCurveToPoint: curve([el.points[0], el.points[1], el.points[2]]); cur = el.points[2]
            case .closeSubpath: out.append((cur, start)); cur = start
            @unknown default: break
            }
        }
        return out
    }
}

extension Annotation {
    /// the point next to `point` along this Line or path — the far end of a
    /// Line, the neighbouring node of a path's end — which a loose end aims
    /// from; nil for other points and kinds
    func neighbour(of point: AttachPoint) -> AttachPoint? {
        switch (point, kind) {
        case (.start, .line): return .end
        case (.end, .line): return .start
        case let (.start, .path(d)) where d.nodes.count > 1:
            return d.nodes.count == 2 ? .end : .node(1)
        case let (.end, .path(d)) where d.nodes.count > 1:
            return d.nodes.count == 2 ? .start : .node(d.nodes.count - 2)
        default: return nil
        }
    }
}
