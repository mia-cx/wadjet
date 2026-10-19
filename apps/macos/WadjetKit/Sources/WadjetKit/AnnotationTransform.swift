import CoreGraphics
import Foundation

/// rotation and flips, applied about the centre of the geometry's bounds: flip first, then rotate.
/// Resizing changes the geometry itself, never this.
public struct AnnotationTransform: Codable, Equatable, Sendable {
    public var rotation: CGFloat        // radians, counterclockwise in AppKit's y-up screen space
    public var flipHorizontal: Bool
    public var flipVertical: Bool
    public static let identity = AnnotationTransform()
    public init(rotation: CGFloat = 0, flipHorizontal: Bool = false, flipVertical: Bool = false) {
        self.rotation = rotation
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }
}

/// a grip on a selected Annotation
public enum SelectionHandle: Hashable, Sendable {
    /// x and y are each -1, 0 or 1: the min edge, the middle, or the max edge of the untransformed bounds
    case resize(x: Int, y: Int)
    /// a Line end (0 start, 1 end); Pen will reuse it for path nodes
    case vertex(Int)
    /// the Line's on-curve midpoint — drag it to bend
    case bend
    case rotate
}

extension AnnotationKind {
    /// the points that define the geometry — a Censor's, shape's or counter's
    /// are its rect's min and max corners, so mapping them resizes
    var points: [CGPoint] {
        switch self {
        case let .line(start, end, bend): [start, end] + (bend.map { [$0] } ?? [])
        case let .censor(rect, _), let .shape(_, rect):
            [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)]
        case let .counter(center, radius, _, _):
            [CGPoint(x: center.x - radius, y: center.y - radius),
             CGPoint(x: center.x + radius, y: center.y + radius)]
        }
    }
    /// the same kind with every defining point mapped — a counter rebuilds
    /// from its mapped box so it stays a circle
    func mapPoints(_ f: (CGPoint) -> CGPoint) -> AnnotationKind {
        switch self {
        case let .line(start, end, bend): return .line(start: f(start), end: f(end), bend: bend.map(f))
        case let .censor(rect, method):
            return .censor(rect: rect.mapCorners(f), method: method)
        case let .shape(kind, rect):
            return .shape(kind, rect: rect.mapCorners(f))
        case let .counter(center, radius, value, format):
            let a = f(CGPoint(x: center.x - radius, y: center.y - radius)),
                b = f(CGPoint(x: center.x + radius, y: center.y + radius))
            return .counter(center: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2),
                            radius: min(abs(a.x - b.x), abs(a.y - b.y)) / 2,
                            value: value, format: format)
        }
    }
    /// resizes with one scale on both axes so it keeps its shape
    var keepsAspect: Bool {
        switch self {
        case .counter: true
        case .line, .censor, .shape: false
        }
    }
    /// an upright box that mapPoints re-standardizes, so a negative resize
    /// scale has to become a flip instead
    var isBox: Bool {
        switch self {
        case .line: false
        case .censor, .shape, .counter: true
        }
    }
    /// tight bounds of the untransformed geometry — a bent Line's frame hugs
    /// the curve; straight segments keep the points' box so a horizontal
    /// Line's height stays exactly 0 (the grip logic keys on `== 0`)
    public var bounds: CGRect {
        let segs = segments
        guard segs.contains(where: { !$0.straight }) else {
            let xs = points.map(\.x), ys = points.map(\.y)
            return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                          width: (xs.max() ?? 0) - (xs.min() ?? 0),
                          height: (ys.max() ?? 0) - (ys.min() ?? 0))
        }
        return PathGeometry.path(segments: segs).boundingBoxOfPath
    }
}

extension Annotation {
    /// geometry -> screen: flip about the bounds centre, then rotate about it
    public var affineTransform: CGAffineTransform {
        let c = CGPoint(x: kind.bounds.midX, y: kind.bounds.midY)
        return CGAffineTransform(translationX: -c.x, y: -c.y)
            .concatenating(CGAffineTransform(scaleX: transform.flipHorizontal ? -1 : 1,
                                             y: transform.flipVertical ? -1 : 1))
            .concatenating(CGAffineTransform(rotationAngle: transform.rotation))
            .concatenating(CGAffineTransform(translationX: c.x, y: c.y))
    }

    /// every point offset by `d` — the transform is about the bounds centre, so it stays valid
    public func moved(by d: CGVector) -> Annotation {
        var a = self
        a.kind = kind.mapPoints { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
        return a
    }

    /// this close to the chord midpoint a bend straightens back to a line
    public static let bendStraightenRadius: CGFloat = 3

    /// the same geometry baked into screen coordinates — lossless for kinds
    /// whose points mapPoints covers (flips+rotation are similarities)
    var baked: Annotation {
        var a = self
        a.kind = kind.mapPoints { $0.applying(affineTransform) }
        a.transform = .identity
        return a
    }

    /// a handle drag, computed from the state at drag start (`self`) so it can't
    /// drift; `constrained` (Shift) snaps a vertex drag to 45° of the other end
    public func dragging(_ handle: SelectionHandle, from start: CGPoint, to point: CGPoint,
                         constrained: Bool = false) -> Annotation {
        switch handle {
        case let .vertex(i):
            // the grip's position at drag start plus the drag — the press needn't land dead-on
            var a = baked
            guard case var .line(s, e, b) = a.kind else { return a }
            let d = CGPoint(x: point.x - start.x, y: point.y - start.y)
            var p = i == 0 ? CGPoint(x: s.x + d.x, y: s.y + d.y)
                           : CGPoint(x: e.x + d.x, y: e.y + d.y)
            if constrained { p = PathGeometry.snapAngle(p, from: i == 0 ? e : s) }
            // the bend keeps its place relative to the chord: z = (B−S)/(E−S)
            // as complex numbers, so B' = S' + z·(E'−S')
            if let bendPt = b {
                let chord = CGPoint(x: e.x - s.x, y: e.y - s.y)
                if chord.x != 0 || chord.y != 0 {
                    let d2 = chord.x * chord.x + chord.y * chord.y
                    let rel = CGPoint(x: bendPt.x - s.x, y: bendPt.y - s.y)
                    let zr = (rel.x * chord.x + rel.y * chord.y) / d2
                    let zi = (rel.y * chord.x - rel.x * chord.y) / d2
                    let (ns, ne) = i == 0 ? (p, e) : (s, p)
                    let newChord = CGPoint(x: ne.x - ns.x, y: ne.y - ns.y)
                    b = CGPoint(x: ns.x + zr * newChord.x - zi * newChord.y,
                                y: ns.y + zr * newChord.y + zi * newChord.x)
                }
            }
            if i == 0 { s = p } else { e = p }
            a.kind = .line(start: s, end: e, bend: b)
            return a
        case .bend:
            var a = baked
            guard case let .line(s, e, b) = a.kind else { return a }
            let mid = CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2)
            let grip = b ?? mid
            let p = CGPoint(x: grip.x + point.x - start.x, y: grip.y + point.y - start.y)
            a.kind = .line(start: s, end: e,
                           bend: hypot(p.x - mid.x, p.y - mid.y) < Self.bendStraightenRadius ? nil : p)
            return a
        case let .resize(x, y):
            let b = kind.bounds, m = affineTransform
            let p = point.applying(m.inverted())
            let anchor = CGPoint(x: b.midX - CGFloat(x) * b.width / 2, y: b.midY - CGFloat(y) * b.height / 2)
            let grip = CGPoint(x: b.midX + CGFloat(x) * b.width / 2, y: b.midY + CGFloat(y) * b.height / 2)
            // a 0 component leaves that axis alone; dragging past the anchor mirrors (negative scale)
            var sx = x == 0 || grip.x == anchor.x ? 1 : (p.x - anchor.x) / (grip.x - anchor.x)
            var sy = y == 0 || grip.y == anchor.y ? 1 : (p.y - anchor.y) / (grip.y - anchor.y)
            if kind.keepsAspect {
                // a counter stays a circle: one scale from the grip's moving
                // axis, the larger on a corner, so the mapped box stays square
                let u = x == 0 ? abs(sy) : y == 0 ? abs(sx) : max(abs(sx), abs(sy))
                sx = x == 0 ? u : (sx < 0 ? -u : u)
                sy = y == 0 ? u : (sy < 0 ? -u : u)
            }
            var new = self
            new.kind = kind.mapPoints { CGPoint(x: anchor.x + ($0.x - anchor.x) * sx,
                                                y: anchor.y + ($0.y - anchor.y) * sy) }
            // a box kind re-standardizes inside mapPoints, so a negative scale
            // can't mirror it — carry the mirror as a geometry-space flip
            // (applied before the rotation, unlike flipped(horizontally:)) and
            // pin the content that sat on the anchor: after the mirror it
            // lives at the anchor reflected about the NEW bounds centre
            var pin = anchor
            if kind.isBox {
                let c = CGPoint(x: new.kind.bounds.midX, y: new.kind.bounds.midY)
                if sx < 0 { new.transform.flipHorizontal.toggle(); pin.x = 2 * c.x - pin.x }
                if sy < 0 { new.transform.flipVertical.toggle(); pin.y = 2 * c.y - pin.y }
            }
            // the new bounds centre moved, so the transform's pivot did too — keep
            // the pin where the anchor was on screen
            let was = anchor.applying(m), now = pin.applying(new.affineTransform)
            return new.moved(by: CGVector(dx: was.x - now.x, dy: was.y - now.y))
        case .rotate:
            let c = CGPoint(x: kind.bounds.midX, y: kind.bounds.midY)
            return rotated(by: atan2(point.y - c.y, point.x - c.x) - atan2(start.y - c.y, start.x - c.x))
        }
    }

    /// positive = counterclockwise
    public func rotated(by angle: CGFloat) -> Annotation {
        var a = self
        a.transform.rotation = (transform.rotation + angle).remainder(dividingBy: 2 * .pi)
        return a
    }

    /// a mirror across the screen's vertical (`horizontally`) or horizontal axis
    /// through the centre, whatever the rotation: the flip toggles and the
    /// rotation unwinds so the rendered shape mirrors instead of spinning
    public func flipped(horizontally: Bool) -> Annotation {
        var a = self
        if horizontally { a.transform.flipHorizontal.toggle() } else { a.transform.flipVertical.toggle() }
        a.transform.rotation = -transform.rotation
        return a
    }

    /// the bounds' corners — (minX,minY) (maxX,minY) (maxX,maxY) (minX,maxY) — on screen
    public var frameCorners: [CGPoint] {
        let b = kind.bounds, m = affineTransform
        return [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
            .map { $0.applying(m) }
    }

    /// screen positions of the selection's grips — a Line gets a grip per end
    /// and one on its curve; every kind also gets `.rotate` above the frame
    /// (other kinds fall back to the bounds' resize grips)
    public func handles(minExtent: CGFloat, rotateOffset: CGFloat) -> [(handle: SelectionHandle, at: CGPoint)] {
        guard case let .line(start, end, bend) = kind else {
            return frameHandles(minExtent: minExtent, rotateOffset: rotateOffset)
        }
        let m = affineTransform
        let mid = bend ?? CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let b = kind.bounds, c = CGPoint(x: b.midX, y: b.midY), v = b.height / 2 + rotateOffset
        return [(.vertex(0), start.applying(m)),
                (.vertex(1), end.applying(m)),
                (.bend, mid.applying(m)),
                (.rotate, CGPoint(x: c.x - v * sin(transform.rotation),
                                  y: c.y + v * cos(transform.rotation)))]
    }

    /// screen positions of the bounds-based grips:
    /// - the 4 corners (x, y ∈ {-1, 1}), a component set to 0 on any axis whose
    ///   extent is exactly 0 (it would resize nothing), deduplicated keeping
    ///   first-seen order (x outer, y inner, -1 before 1) — so a horizontal
    ///   Line gets only resize(-1,0) at its left end and resize(1,0) at its
    ///   right end, and an undersized diagonal keeps all 4 corners
    /// - the 4 edge midpoints resize(0,±1), resize(±1,0), only when BOTH width
    ///   and height are ≥ `minExtent`
    /// - then `.rotate` above the frame's top centre — placed by rotation alone
    ///   so a flip can't put it below
    public func frameHandles(minExtent: CGFloat, rotateOffset: CGFloat) -> [(handle: SelectionHandle, at: CGPoint)] {
        let b = kind.bounds, m = affineTransform
        func at(_ x: Int, _ y: Int) -> CGPoint {
            CGPoint(x: b.midX + CGFloat(x) * b.width / 2,
                    y: b.midY + CGFloat(y) * b.height / 2).applying(m)
        }
        var out: [(handle: SelectionHandle, at: CGPoint)] = []
        var seen = Set<SelectionHandle>()
        for x in -1...1 where x != 0 { for y in -1...1 where y != 0 {
            let h = SelectionHandle.resize(x: b.width == 0 ? 0 : x, y: b.height == 0 ? 0 : y)
            if seen.insert(h).inserted { out.append((h, at(x, y))) }
        } }
        if b.width >= minExtent && b.height >= minExtent {
            for (x, y) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
                out.append((.resize(x: x, y: y), at(x, y)))
            }
        }
        let c = CGPoint(x: b.midX, y: b.midY), v = b.height / 2 + rotateOffset
        out.append((.rotate, CGPoint(x: c.x - v * sin(transform.rotation),
                                     y: c.y + v * cos(transform.rotation))))
        return out
    }

    /// the grip nearest `p`, if within `radius` — nearest, not first, so grips
    /// crowded closer than `radius` resolve to the one the press meant
    public func handle(at p: CGPoint, radius: CGFloat, minExtent: CGFloat,
                       rotateOffset: CGFloat) -> SelectionHandle? {
        handles(minExtent: minExtent, rotateOffset: rotateOffset)
            .map { ($0.handle, hypot($0.at.x - p.x, $0.at.y - p.y)) }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?.0
    }
}

private extension CGRect {
    /// the rect through two mapped corners — a negative resize scale mirrors
    /// them, so it re-standardizes
    func mapCorners(_ f: (CGPoint) -> CGPoint) -> CGRect {
        let a = f(CGPoint(x: minX, y: minY)), b = f(CGPoint(x: maxX, y: maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y).standardized
    }
}
