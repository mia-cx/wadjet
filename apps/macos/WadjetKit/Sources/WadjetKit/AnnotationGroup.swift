import CoreGraphics
import Foundation

/// Several selected Annotations transformed as one through a shared bounding
/// box, after Illustrator's Selection tool: one axis-aligned box around them
/// all, resize grips at its corners and edge midpoints, and a rotate grip
/// above it. Every function works from the Annotations' state at drag start,
/// so a long drag can't drift. Strokes keep their width, as Illustrator's
/// default "Scale Strokes" is off.
public enum AnnotationGroup {
    /// the smallest extent a group resize leaves on an axis: a grip dragged
    /// onto the opposite edge never collapses the group, and one dragged past
    /// it mirrors the group, as Illustrator's does
    public static let minExtent: CGFloat = 1

    /// the axis-aligned box around every Annotation's on-screen frame
    public static func bounds(of annotations: [Annotation]) -> CGRect {
        let pts = annotations.flatMap(\.frameCorners)
        guard let first = pts.first else { return .null }
        var r = CGRect(origin: first, size: .zero)
        for p in pts.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    /// the shared box's grips: the 4 corners, the 4 edge midpoints when both
    /// sides are at least `minExtent`, and `.rotate` `rotateOffset` above the
    /// top edge's middle. An axis with no extent loses its corner component,
    /// as a single Annotation's frame does.
    public static func handles(of b: CGRect, minExtent: CGFloat,
                               rotateOffset: CGFloat) -> [(handle: SelectionHandle, at: CGPoint)] {
        func at(_ x: Int, _ y: Int) -> CGPoint {
            CGPoint(x: b.midX + CGFloat(x) * b.width / 2, y: b.midY + CGFloat(y) * b.height / 2)
        }
        var out: [(handle: SelectionHandle, at: CGPoint)] = []
        var seen = Set<SelectionHandle>()
        for x in [-1, 1] { for y in [-1, 1] {
            let h = SelectionHandle.resize(x: b.width == 0 ? 0 : x, y: b.height == 0 ? 0 : y)
            if seen.insert(h).inserted { out.append((h, at(x, y))) }
        } }
        if b.width >= minExtent && b.height >= minExtent {
            for (x, y) in [(0, -1), (0, 1), (-1, 0), (1, 0)] { out.append((.resize(x: x, y: y), at(x, y))) }
        }
        out.append((.rotate, CGPoint(x: b.midX, y: b.maxY + rotateOffset)))
        return out
    }

    /// the grip nearest `p` within `radius`, if any
    public static func handle(at p: CGPoint, of b: CGRect, radius: CGFloat, minExtent: CGFloat,
                              rotateOffset: CGFloat) -> SelectionHandle? {
        handles(of: b, minExtent: minExtent, rotateOffset: rotateOffset)
            .map { ($0.handle, hypot($0.at.x - p.x, $0.at.y - p.y)) }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?.0
    }

    public static func moved(_ annotations: [Annotation], by d: CGVector) -> [Annotation] {
        annotations.map { $0.moved(by: d) }
    }

    /// a grip drag on the shared box, from the state at drag start: a resize
    /// grip scales (`proportional`, Shift, keeps the box's aspect; `fromCentre`,
    /// Option, scales about the centre rather than the opposite grip), the
    /// rotate grip turns about the centre (`proportional` snaps to 45°).
    /// Point grips belong to single Annotations and change nothing here.
    public static func dragging(_ annotations: [Annotation], _ handle: SelectionHandle,
                                from start: CGPoint, to point: CGPoint,
                                proportional: Bool = false, fromCentre: Bool = false) -> [Annotation] {
        switch handle {
        case .resize:
            return resized(annotations, handle, from: start, to: point,
                           proportional: proportional, fromCentre: fromCentre)
        case .rotate:
            let b = bounds(of: annotations), c = CGPoint(x: b.midX, y: b.midY)
            var angle = atan2(point.y - c.y, point.x - c.x) - atan2(start.y - c.y, start.x - c.x)
            if proportional { angle = (angle / (.pi / 4)).rounded() * (.pi / 4) }
            return rotated(annotations, by: angle)
        case .vertex, .bend, .tangent, .source, .cornerRadius:
            return annotations
        }
    }

    /// a resize grip `.resize(x:y:)` dragged from `start` to `point`
    public static func resized(_ annotations: [Annotation], _ handle: SelectionHandle,
                               from start: CGPoint, to point: CGPoint,
                               proportional: Bool = false, fromCentre: Bool = false) -> [Annotation] {
        guard case let .resize(x, y) = handle else { return annotations }
        let b = bounds(of: annotations)
        guard !b.isNull else { return annotations }
        let grip = CGPoint(x: b.midX + CGFloat(x) * b.width / 2, y: b.midY + CGFloat(y) * b.height / 2)
        let anchor = fromCentre ? CGPoint(x: b.midX, y: b.midY)
            : CGPoint(x: b.midX - CGFloat(x) * b.width / 2, y: b.midY - CGFloat(y) * b.height / 2)
        // the grip follows the pointer's delta, so an off-centre press doesn't jump
        let target = CGPoint(x: grip.x + point.x - start.x, y: grip.y + point.y - start.y)
        func scale(_ moving: Int, _ t: CGFloat, _ g: CGFloat, _ a: CGFloat, _ extent: CGFloat) -> CGFloat {
            guard moving != 0, g != a else { return 1 }
            // past the anchor the scale turns negative and mirrors; near it,
            // never thinner than a sliver on either side
            let s = (t - a) / (g - a), floor = minExtent / extent
            return abs(s) >= floor ? s : s < 0 ? -floor : floor
        }
        var sx = scale(x, target.x, grip.x, anchor.x, b.width)
        var sy = scale(y, target.y, grip.y, anchor.y, b.height)
        if proportional {
            // an edge grip scales both axes by its own; a corner by the
            // larger. A moving axis keeps its sign, so it can still mirror;
            // an edge grip's other axis grows without mirroring
            let u = x == 0 ? abs(sy) : y == 0 ? abs(sx) : max(abs(sx), abs(sy))
            sx = b.width == 0 ? 1 : x != 0 && sx < 0 ? -u : u
            sy = b.height == 0 ? 1 : y != 0 && sy < 0 ? -u : u
        }
        return scaled(annotations, x: sx, y: sy, about: anchor)
    }

    /// every Annotation scaled by `sx`, `sy` about `anchor` in screen space
    public static func scaled(_ annotations: [Annotation], x sx: CGFloat, y sy: CGFloat,
                              about anchor: CGPoint) -> [Annotation] {
        annotations.map { $0.scaled(x: sx, y: sy, about: anchor) }
    }

    /// every Annotation turned by `angle` (radians, counterclockwise) about the shared box's centre
    public static func rotated(_ annotations: [Annotation], by angle: CGFloat) -> [Annotation] {
        let b = bounds(of: annotations)
        guard !b.isNull else { return annotations }
        let c = CGPoint(x: b.midX, y: b.midY)
        return annotations.map { $0.rotated(by: angle, about: c) }
    }

    /// the group mirrored across the shared box's vertical (`horizontally`)
    /// or horizontal centre line
    public static func flipped(_ annotations: [Annotation], horizontally: Bool) -> [Annotation] {
        let b = bounds(of: annotations)
        guard !b.isNull else { return annotations }
        return annotations.map { a in
            let c = a.centre
            let d = horizontally ? CGVector(dx: 2 * (b.midX - c.x), dy: 0)
                                 : CGVector(dx: 0, dy: 2 * (b.midY - c.y))
            return a.moved(by: d).flipped(horizontally: horizontally)
        }
    }
}

extension Annotation {
    /// the centre of the untransformed bounds — rotation and flips pivot
    /// there, so it is also the on-screen centre
    public var centre: CGPoint { CGPoint(x: kind.bounds.midX, y: kind.bounds.midY) }

    /// scaled by `sx`, `sy` about `anchor` in screen space, its rotation kept.
    /// The centre lands exactly where the scale takes it. A negative scale
    /// mirrors the Annotation on screen as Flip does. A Line or path at an
    /// angle the scale would skew takes the scale into its points exactly,
    /// keeping its rotation, as Illustrator bakes a group scale into its paths.
    /// Any other kind scales along its own axes: exactly when it's upright,
    /// quarter-turned, or scaled evenly; otherwise by how much each of its
    /// axes stretches, since a box can't skew. Kinds that keep their aspect
    /// (counters, images, windows) take the axis that changes most.
    public func scaled(x sx: CGFloat, y sy: CGFloat, about anchor: CGPoint) -> Annotation {
        let c = centre
        let target = CGPoint(x: anchor.x + (c.x - anchor.x) * sx, y: anchor.y + (c.y - anchor.y) * sy)
        let r = kind.transforms ? transform.rotation : 0
        if kind.isPoints, abs(sx) != abs(sy), abs(sin(2 * r)) > 1e-9 {
            // the screen-space scale applied to the drawn points, then taken
            // back into geometry under the same rotation and flips: exact,
            // skew included, and a whole follower's frame doesn't jump
            let m = affineTransform, inv = m.inverted()
            let s = CGAffineTransform(translationX: anchor.x, y: anchor.y)
                .scaledBy(x: sx, y: sy).translatedBy(x: -anchor.x, y: -anchor.y)
            var a = self
            a.kind = kind.mapPoints { $0.applying(m).applying(s).applying(inv) }
            // the bounds centre is the pivot and it moved: pin one point back
            guard let p0 = kind.points.first, let g0 = a.kind.points.first else { return a }
            let want = p0.applying(m).applying(s), now = g0.applying(a.affineTransform)
            return a.moved(by: CGVector(dx: want.x - now.x, dy: want.y - now.y))
        }
        // the lengths the scale gives the Annotation's own unit axes
        var lx = hypot(sx * cos(r), sy * sin(r)), ly = hypot(sx * sin(r), sy * cos(r))
        if kind.keepsAspect {
            let u = abs(lx - 1) >= abs(ly - 1) ? lx : ly
            lx = u; ly = u
        }
        var a = self
        a.kind = kind.mapPoints { CGPoint(x: c.x + ($0.x - c.x) * lx, y: c.y + ($0.y - c.y) * ly) }
        if kind.transforms {
            if sx < 0 { a = a.flipped(horizontally: true) }
            if sy < 0 { a = a.flipped(horizontally: false) }
        }
        // Text and counters rebuild their box, so re-centre on the target
        let now = a.centre
        return a.moved(by: CGVector(dx: target.x - now.x, dy: target.y - now.y))
    }

    /// turned by `angle` about `pivot`: the centre swings round it and the
    /// Annotation's own rotation adds `angle` — a Magnify, which doesn't
    /// rotate, only swings
    public func rotated(by angle: CGFloat, about pivot: CGPoint) -> Annotation {
        let c = centre, v = CGPoint(x: c.x - pivot.x, y: c.y - pivot.y)
        let to = CGPoint(x: pivot.x + v.x * cos(angle) - v.y * sin(angle),
                         y: pivot.y + v.x * sin(angle) + v.y * cos(angle))
        let a = moved(by: CGVector(dx: to.x - c.x, dy: to.y - c.y))
        return kind.transforms ? a.rotated(by: angle) : a
    }
}
