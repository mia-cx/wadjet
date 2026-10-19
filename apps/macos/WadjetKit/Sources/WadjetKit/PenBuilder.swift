import CoreGraphics
import Foundation

/// builds a Pen path press by press, like Affinity's Pen
public struct PenBuilder: Equatable, Sendable {
    public private(set) var path = PathData()   // starts empty, open
    /// the node the last press created or hit — the one `drag` shapes
    private var pressed: Int?

    public init() {}

    /// a press at `p`: on the first node of a path with ≥ 2 nodes (within
    /// `closeRadius`) it closes the path and returns true (finished); otherwise
    /// it adds a corner node at `p` — `constrained` snaps it to 45° from the
    /// previous node — and returns false
    public mutating func press(at p: CGPoint, closeRadius: CGFloat,
                               constrained: Bool = false) -> Bool {
        if !path.closed, path.nodes.count >= 2,
           hypot(p.x - path.nodes[0].anchor.x, p.y - path.nodes[0].anchor.y) <= closeRadius {
            path.closed = true
            pressed = 0
            return true
        }
        var p = p
        if constrained, let last = path.nodes.last {
            p = PathGeometry.snapAngle(p, from: last.anchor)
        }
        path.nodes.append(PathNode(anchor: p))
        pressed = path.nodes.count - 1
        return false
    }

    /// dragging after a press pulls the pressed node's handleOut to `p` and
    /// mirrors handleIn through the anchor (`constrained`: 45° from the
    /// anchor); after a closing press it shapes the first node the same way
    public mutating func drag(to p: CGPoint, constrained: Bool = false) {
        guard let i = pressed, path.nodes.indices.contains(i) else { return }
        var p = p
        let a = path.nodes[i].anchor
        if constrained { p = PathGeometry.snapAngle(p, from: a) }
        path.nodes[i].handleOut = p
        path.nodes[i].handleIn = CGPoint(x: 2 * a.x - p.x, y: 2 * a.y - p.y)
    }

    /// the path plus a corner node at `hover`, for the rubber-band preview
    /// while building; a closed path (its closing press still shaping the
    /// first node) previews as itself
    public func preview(to hover: CGPoint) -> PathData {
        guard !path.closed else { return path }
        var d = path
        d.nodes.append(PathNode(anchor: hover))
        return d
    }

    /// the path to keep, or nil with fewer than 2 nodes
    public var finished: PathData? { path.nodes.count >= 2 ? path : nil }
}
