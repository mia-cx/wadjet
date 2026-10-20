import CoreGraphics
import Foundation

/// one place a point can attach to: the target, the anchor that holds it, and where that is on screen
public struct AttachSpot: Equatable, Sendable {
    public var target: Annotation.ID
    public var anchor: AttachAnchor
    public var at: CGPoint
    public init(target: Annotation.ID, anchor: AttachAnchor, at: CGPoint) {
        self.target = target
        self.anchor = anchor
        self.at = at
    }
}

/// what a dragged point is over: the Annotation it would attach to, that
/// Annotation's named spots to highlight, and the spot a drop attaches to
/// (nil while the point is over the target but near none of its spots or its outline)
public struct AttachHover: Equatable, Sendable {
    public var target: Annotation
    public var spots: [AttachSpot]
    public var snapped: AttachSpot?
}

/// Finds attach targets for a dragged point: an Annotation's named spots
/// (corners, edge midpoints, path and shape vertices) and the nearest point
/// on its outline.
public enum AttachFinder {
    /// the spots worth naming on `a`: corners and edge midpoints of a box;
    /// an ellipse's or counter's four edge midpoints, the ones on its
    /// outline; a polygon's or star's vertices; a Line's ends and middle; a
    /// path's nodes
    public static func spots(on a: Annotation) -> [AttachSpot] {
        func frame(_ u: [CGPoint]) -> [AttachSpot] {
            u.compactMap { p in a.position(of: .frame(p)).map { AttachSpot(target: a.id, anchor: .frame(p), at: $0) } }
        }
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
        let midpoints = [CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0.5), CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: 0.5)]
        switch a.kind {
        case .line:
            return [0, 0.5, 1].compactMap { t in
                a.position(of: .segment(0, t: t)).map { AttachSpot(target: a.id, anchor: .segment(0, t: t), at: $0) }
            }
        case let .path(d):
            let n = a.kind.segments.count
            guard n > 0 else { return [] }
            var anchors = (0..<n).map { AttachAnchor.segment($0, t: 0) }
            if !d.closed { anchors.append(.segment(n - 1, t: 1)) }
            return anchors.compactMap { an in a.position(of: an).map { AttachSpot(target: a.id, anchor: an, at: $0) } }
        case .shape(.ellipse, _), .counter:
            return frame(midpoints)
        case let .shape(.polygon(sides), _):
            return frame(vertices(count: max(3, sides)) { _ in 1 })
        case let .shape(.star(points, ratio), _):
            let r = min(0.95, max(0.05, ratio))
            return frame(vertices(count: 2 * max(3, points)) { $0 % 2 == 1 ? r : 1 })
        default:
            return frame(corners + midpoints)
        }
    }

    /// a polygon's or star's vertices as frame positions, matching ShapeKind's outline
    private static func vertices(count: Int, radius: (Int) -> CGFloat) -> [CGPoint] {
        (0..<count).map { k in
            let ang = CGFloat.pi / 2 + 2 * .pi * CGFloat(k) / CGFloat(count), r = radius(k)
            return CGPoint(x: 0.5 + 0.5 * r * cos(ang), y: 0.5 + 0.5 * r * sin(ang))
        }
    }

    /// the point on `a`'s outline nearest `p`: along a Line's or path's
    /// segments, or around a box's, shape's, or magnifier's edge
    public static func nearestOnOutline(of a: Annotation, to p: CGPoint) -> AttachSpot? {
        switch a.kind {
        case .line, .path:
            guard let anchor = a.nearestSegmentAnchor(to: p) else { return nil }
            return a.position(of: anchor).map { AttachSpot(target: a.id, anchor: anchor, at: $0) }
        default:
            guard let q = nearest(on: outline(of: a), to: p) else { return nil }
            let anchor = a.frameAnchor(at: q)
            return a.position(of: anchor).map { AttachSpot(target: a.id, anchor: anchor, at: $0) }
        }
    }

    /// the edge a point attaches around, on screen: a Magnify's magnifier
    /// silhouette, every other kind's own outline
    public static func outline(of a: Annotation) -> CGPath {
        if case let .magnify(m) = a.kind { return m.options.shape.path(in: m.frame) }
        return PathGeometry.path(for: a)
    }

    /// what a point of `source` dragged to `p` would attach to. A named spot
    /// within `radius` wins, the nearest of all; then the nearest outline
    /// point within `radius` of the front-most Annotation that has one; then,
    /// unsnapped, the front-most Annotation under `p` or inside its outline. Hidden Annotations,
    /// the source, and anything that would close a cycle are skipped.
    public static func hover(at p: CGPoint, in stack: LayerStack, attaching source: Annotation.ID,
                             _ point: AttachPoint, radius: CGFloat) -> AttachHover? {
        let eligible = stack.annotations.reversed().filter {
            !$0.hidden && stack.canAttach(source, point, to: $0.id)
        }
        func dist(_ s: AttachSpot) -> CGFloat { hypot(s.at.x - p.x, s.at.y - p.y) }
        var named: (AttachSpot, Annotation, [AttachSpot])?
        for a in eligible {
            let spots = spots(on: a)
            if let s = spots.filter({ dist($0) <= radius }).min(by: { dist($0) < dist($1) }),
               named == nil || dist(s) < dist(named!.0) {
                named = (s, a, spots)
            }
        }
        if let (s, a, spots) = named { return AttachHover(target: a, spots: spots, snapped: s) }
        for a in eligible {
            if let s = nearestOnOutline(of: a, to: p), dist(s) <= radius {
                return AttachHover(target: a, spots: spots(on: a), snapped: s)
            }
        }
        // inside a hollow shape counts, as it does in tldraw
        if let a = eligible.first(where: {
            (!$0.kind.insertsAttachSegments && outline(of: $0).contains(p))
                || PathGeometry.hitTest($0, at: p, tolerance: radius)
        }) {
            return AttachHover(target: a, spots: spots(on: a), snapped: nil)
        }
        return nil
    }

    /// the nearest point to `p` on `path`, its curves flattened
    static func nearest(on path: CGPath, to p: CGPoint) -> CGPoint? {
        var best: (CGPoint, CGFloat)?, cur = CGPoint.zero, start = CGPoint.zero
        func consider(_ a: CGPoint, _ b: CGPoint) {
            let dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy
            let t = l2 == 0 ? 0 : min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
            let q = CGPoint(x: a.x + t * dx, y: a.y + t * dy), d = hypot(q.x - p.x, q.y - p.y)
            if best == nil || d < best!.1 { best = (q, d) }
        }
        func curve(_ pts: [CGPoint]) {
            // a quadratic or cubic from `cur` through its controls, in 24 chords
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
                consider(prev, level[0])
                prev = level[0]
            }
        }
        path.applyWithBlock { e in
            let el = e.pointee
            switch el.type {
            case .moveToPoint: cur = el.points[0]; start = cur
            case .addLineToPoint: consider(cur, el.points[0]); cur = el.points[0]
            case .addQuadCurveToPoint: curve([el.points[0], el.points[1]]); cur = el.points[1]
            case .addCurveToPoint: curve([el.points[0], el.points[1], el.points[2]]); cur = el.points[2]
            case .closeSubpath: consider(cur, start); cur = start
            @unknown default: break
            }
        }
        return best?.0
    }
}

extension AnnotationKind {
    /// Lines and paths attach by segment, everything else by its frame
    var insertsAttachSegments: Bool {
        switch self {
        case .line, .path: true
        default: false
        }
    }
}

extension Annotation {
    /// a copy with `point` moved to screen point `p`, the rest re-solved
    /// around it as an attachment would — the dragged point's preview while it
    /// sits on an attach spot. Unchanged when this kind has no such point.
    public func moving(_ point: AttachPoint, to p: CGPoint) -> Annotation {
        placing(point, at: p)
    }

    /// the attachable point a grip drags: a Line's bend, or a vertex grip's
    /// anchor (as Direct Select's anchors name them) — nil for every other grip
    public func attachPoint(for handle: SelectionHandle) -> AttachPoint? {
        switch handle {
        case .bend: if case .line = kind { return .bend } else { return nil }
        case let .vertex(i): return attachPoint(forAnchor: i)
        default: return nil
        }
    }

    /// a copy attached to nothing, so a drag can carry it away whole
    public var freed: Annotation {
        var a = self
        a.attachments = []
        return a
    }

    /// a copy with `point` free, so a drag can carry it away
    public func detaching(_ point: AttachPoint) -> Annotation {
        var a = self
        a.attachments.removeAll { $0.point == point }
        return a
    }
}
