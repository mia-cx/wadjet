import CoreGraphics
import Foundation

/// ⌥ on an anchor, after Illustrator's Anchor Point tool (the Pen with ⌥):
/// a click converts the anchor between smooth and corner, a drag pulls out
/// new smooth handles. Both work on a path's baked geometry; a Shape becomes
/// its outline path first, as any anchor edit makes it. A Brush stroke drops
/// its raw samples, so a later Smoothing change can't refit the edit away.
extension PathNode {
    /// both handles off the anchor and leaving it in opposite directions
    public var isSmooth: Bool {
        guard let i = handleIn, let o = handleOut else { return false }
        return Annotation.collinear(i, o, through: anchor)
    }
}

extension Annotation {
    /// the ⌥-click on anchor `i`: a smooth anchor turns corner, its handles
    /// retracted onto it; any other anchor turns smooth, with symmetric
    /// handles along the line through its neighbours (a path's end, with one
    /// neighbour, aims at it). nil when `i` has no anchor to convert, or no
    /// neighbour to aim along: Lines and other kinds keep their own grips.
    public func convertingAnchor(_ i: Int) -> Annotation? {
        guard var (a, data) = anchorEditable(i) else { return nil }
        let n = data.nodes[i]
        if n.isSmooth {
            data.nodes[i].handleIn = nil
            data.nodes[i].handleOut = nil
        } else {
            guard let t = Self.smoothTangent(data, at: i) else { return nil }
            data.nodes[i].handleIn = CGPoint(x: n.anchor.x - t.dx, y: n.anchor.y - t.dy)
            data.nodes[i].handleOut = CGPoint(x: n.anchor.x + t.dx, y: n.anchor.y + t.dy)
        }
        a.kind = .path(data)
        return a
    }

    /// the ⌥-drag from anchor `i` to `p` on screen: its outgoing handle
    /// follows the pointer and the incoming one mirrors it through the
    /// anchor — a smooth node, whatever it was. `constrained` (Shift) holds
    /// the handle on a 45° ray. Handles dragged back onto the anchor retract.
    public func pullingHandles(_ i: Int, to p: CGPoint, constrained: Bool = false) -> Annotation? {
        guard var (a, data) = anchorEditable(i) else { return nil }
        let anchor = data.nodes[i].anchor
        let h = constrained ? PathGeometry.snapAngle(p, from: anchor) : p
        if hypot(h.x - anchor.x, h.y - anchor.y) < 1e-9 {
            data.nodes[i].handleIn = nil
            data.nodes[i].handleOut = nil
        } else {
            data.nodes[i].handleOut = h
            data.nodes[i].handleIn = CGPoint(x: 2 * anchor.x - h.x, y: 2 * anchor.y - h.y)
        }
        a.kind = .path(data)
        return a
    }

    /// this Annotation baked to screen coordinates as a path, with Brush
    /// samples dropped — nil unless it's a path or Shape with anchor `i`
    private func anchorEditable(_ i: Int) -> (Annotation, PathData)? {
        let a: Annotation
        switch kind {
        case .path: a = baked
        case .shape: a = outlinePath.baked
        default: return nil
        }
        guard case var .path(data) = a.kind, data.nodes.indices.contains(i) else { return nil }
        data.rawPoints = nil
        data.smoothing = nil
        return (a, data)
    }

    /// the outgoing handle's offset for a smooth node `i`: a sixth of the
    /// chord between its neighbours (Catmull-Rom's tangent), or a third of
    /// the way to its one neighbour at an open path's end. nil without a
    /// neighbour, or when both neighbours sit on one spot.
    static func smoothTangent(_ data: PathData, at i: Int) -> CGVector? {
        let n = data.nodes.count, anchor = data.nodes[i].anchor
        let prev = i > 0 || data.closed ? data.nodes[(i - 1 + n) % n].anchor : nil
        let next = i < n - 1 || data.closed ? data.nodes[(i + 1) % n].anchor : nil
        let t: CGVector
        switch (prev, next) {
        case let (p?, q?) where n > 2: t = CGVector(dx: (q.x - p.x) / 6, dy: (q.y - p.y) / 6)
        case let (_, q?): t = CGVector(dx: (q.x - anchor.x) / 3, dy: (q.y - anchor.y) / 3)
        case let (p?, nil): t = CGVector(dx: (anchor.x - p.x) / 3, dy: (anchor.y - p.y) / 3)
        case (nil, nil): return nil
        }
        return hypot(t.dx, t.dy) < 1e-9 ? nil : t
    }
}
