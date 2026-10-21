import CoreGraphics
import Foundation

/// A bend grip on every segment of a selected path, so a Line keeps bending
/// after the Draw Tool adds a point to it: the grip sits on the segment's
/// on-curve midpoint, and dragging it bends that segment alone. The anchors
/// stay put; the two inner bezier handles move, as dragging a segment does
/// in Illustrator and Affinity.
extension Annotation {
    /// one `.segmentBend` grip per segment of a path, on screen at its
    /// on-curve midpoint (t = 0.5), closing segment included. A segment whose
    /// midpoint sits nearer than `spacing` to either of its anchors gets none,
    /// so short segments (most of a dense Brush stroke's) don't crowd their
    /// anchors. A Line keeps its own `.bend`; other kinds get none.
    public func segmentBendGrips(spacing: CGFloat) -> [(handle: SelectionHandle, at: CGPoint)] {
        guard case let .path(data) = kind, data.nodes.count >= 2 else { return [] }
        let m = affineTransform
        return kind.segments.enumerated().compactMap { i, s in
            let mid = s.point(at: 0.5).applying(m)
            let a = s.p0.applying(m), b = s.p3.applying(m)
            guard hypot(mid.x - a.x, mid.y - a.y) >= spacing,
                  hypot(mid.x - b.x, mid.y - b.y) >= spacing else { return nil }
            return (.segmentBend(i), mid)
        }
    }

    /// segment `i` bent so its midpoint follows the drag from `start` to
    /// `point` (screen), computed from the state at drag start. Both inner
    /// handles shift by 4/3 of the drag, which moves the cubic's t = 0.5 point
    /// by exactly the drag. A straight segment's handles start at the chord's
    /// thirds, so it bends into the same arc a Line's bend draws. An end node
    /// whose two handles were collinear stays smooth: its other handle turns
    /// with this one, at its own length. Dragged back to straight (both
    /// handles within `bendStraightenRadius` of the chord), the segment
    /// becomes straight again, and a smooth end's other handle turns onto
    /// the chord's line. A Brush stroke drops its samples, because a refit
    /// would undo it.
    public func bendingSegment(_ i: Int, from start: CGPoint, to point: CGPoint) -> Annotation {
        var a = baked
        guard case var .path(data) = a.kind else { return a }
        let n = data.nodes.count
        guard n >= 2, i >= 0, i < n - 1 || (data.closed && i == n - 1) else { return a }
        let j = (i + 1) % n
        let d = CGPoint(x: (point.x - start.x) * 4 / 3, y: (point.y - start.y) * 4 / 3)
        let p0 = data.nodes[i].anchor, p3 = data.nodes[j].anchor
        let old1 = data.nodes[i].handleOut, old2 = data.nodes[j].handleIn
        // a straight segment as the cubic of its chord's quadratic; a curved
        // one's missing handle collapses to its anchor, as it draws
        let straight = old1 == nil && old2 == nil
        let from1 = old1 ?? (straight ? CGPoint(x: p0.x + (p3.x - p0.x) / 3, y: p0.y + (p3.y - p0.y) / 3) : p0)
        let from2 = old2 ?? (straight ? CGPoint(x: p3.x + (p0.x - p3.x) / 3, y: p3.y + (p0.y - p3.y) / 3) : p3)
        let c1 = CGPoint(x: from1.x + d.x, y: from1.y + d.y)
        let c2 = CGPoint(x: from2.x + d.x, y: from2.y + d.y)
        if Self.liesOnChord(c1, p0, p3), Self.liesOnChord(c2, p0, p3) {
            data.nodes[i].handleOut = nil
            data.nodes[j].handleIn = nil
            // a straight segment leaves each end along the chord: a smooth
            // end's other handle lines up with it
            data.nodes[i].handleIn = Self.keptSmooth(data.nodes[i].handleIn, anchor: p0, was: old1, now: p3)
            data.nodes[j].handleOut = Self.keptSmooth(data.nodes[j].handleOut, anchor: p3, was: old2, now: p0)
        } else {
            data.nodes[i].handleOut = c1
            data.nodes[j].handleIn = c2
            data.nodes[i].handleIn = Self.keptSmooth(data.nodes[i].handleIn, anchor: p0, was: old1, now: c1)
            data.nodes[j].handleOut = Self.keptSmooth(data.nodes[j].handleOut, anchor: p3, was: old2, now: c2)
        }
        data.rawPoints = nil
        data.smoothing = nil
        a.kind = .path(data)
        return a
    }

    /// whether `c` sits within `bendStraightenRadius` of the chord p0–p3,
    /// between its ends
    private static func liesOnChord(_ c: CGPoint, _ p0: CGPoint, _ p3: CGPoint) -> Bool {
        let r = bendStraightenRadius
        let vx = p3.x - p0.x, vy = p3.y - p0.y, len = hypot(vx, vy)
        guard len > 1e-9 else { return hypot(c.x - p0.x, c.y - p0.y) <= r }
        let wx = c.x - p0.x, wy = c.y - p0.y
        let along = (wx * vx + wy * vy) / len, off = abs(wx * vy - wy * vx) / len
        return off <= r && along >= -r && along <= len + r
    }

    /// `other`, the anchor's opposite handle, turned to stay collinear with
    /// the moved handle when the two were collinear (a smooth node) before;
    /// unchanged at a corner, or when either handle was missing
    private static func keptSmooth(_ other: CGPoint?, anchor: CGPoint, was: CGPoint?, now: CGPoint) -> CGPoint? {
        guard let other, let was else { return other }
        let ux = was.x - anchor.x, uy = was.y - anchor.y, ox = other.x - anchor.x, oy = other.y - anchor.y
        let lu = hypot(ux, uy), lo = hypot(ox, oy)
        guard lu > 1e-9, lo > 1e-9 else { return other }
        // opposite directions within about half a degree
        let cos = (ux * ox + uy * oy) / (lu * lo)
        guard cos < -0.99996 else { return other }
        let nx = anchor.x - now.x, ny = anchor.y - now.y, ln = hypot(nx, ny)
        guard ln > 1e-9 else { return other }
        return CGPoint(x: anchor.x + nx / ln * lo, y: anchor.y + ny / ln * lo)
    }
}

extension SelectionHandle {
    /// a Line's bend or a path segment's: drags that bend a stroke
    var isBend: Bool {
        switch self {
        case .bend, .segmentBend: true
        default: false
        }
    }
}
