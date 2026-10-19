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
    case rotate
}

extension AnnotationKind {
    /// the points that define the geometry
    var points: [CGPoint] {
        switch self { case let .line(start, end): [start, end] }
    }
    /// the same kind with every defining point mapped
    func mapPoints(_ f: (CGPoint) -> CGPoint) -> AnnotationKind {
        switch self { case let .line(start, end): .line(start: f(start), end: f(end)) }
    }
    /// bounding box of `points` — may have zero width or height
    public var bounds: CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                      width: (xs.max() ?? 0) - (xs.min() ?? 0),
                      height: (ys.max() ?? 0) - (ys.min() ?? 0))
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

    /// a handle drag, computed from the state at drag start (`self`) so it can't drift
    public func dragging(_ handle: SelectionHandle, from start: CGPoint, to point: CGPoint) -> Annotation {
        switch handle {
        case let .resize(x, y):
            let b = kind.bounds, m = affineTransform
            let p = point.applying(m.inverted())
            let anchor = CGPoint(x: b.midX - CGFloat(x) * b.width / 2, y: b.midY - CGFloat(y) * b.height / 2)
            let grip = CGPoint(x: b.midX + CGFloat(x) * b.width / 2, y: b.midY + CGFloat(y) * b.height / 2)
            // a 0 component leaves that axis alone; dragging past the anchor mirrors (negative scale)
            let sx = x == 0 || grip.x == anchor.x ? 1 : (p.x - anchor.x) / (grip.x - anchor.x)
            let sy = y == 0 || grip.y == anchor.y ? 1 : (p.y - anchor.y) / (grip.y - anchor.y)
            var new = self
            new.kind = kind.mapPoints { CGPoint(x: anchor.x + ($0.x - anchor.x) * sx,
                                                y: anchor.y + ($0.y - anchor.y) * sy) }
            // the new bounds centre moved, so the transform's pivot did too — keep
            // the anchor where it was on screen
            let was = anchor.applying(m), now = anchor.applying(new.affineTransform)
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

    /// screen positions of the selection's grips:
    /// - the 4 corners (x, y ∈ {-1, 1}), a component set to 0 on any axis whose
    ///   extent is exactly 0 (it would resize nothing), deduplicated keeping
    ///   first-seen order (x outer, y inner, -1 before 1) — so a horizontal
    ///   Line gets only resize(-1,0) at its left end and resize(1,0) at its
    ///   right end, and an undersized diagonal keeps all 4 corners
    /// - the 4 edge midpoints resize(0,±1), resize(±1,0), only when BOTH width
    ///   and height are ≥ `minExtent`
    /// - then `.rotate` above the frame's top centre — placed by rotation alone
    ///   so a flip can't put it below
    public func handles(minExtent: CGFloat, rotateOffset: CGFloat) -> [(handle: SelectionHandle, at: CGPoint)] {
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
