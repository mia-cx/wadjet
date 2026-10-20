import CoreGraphics

extension Annotation {
    /// a grip drag that snaps: a resize or vertex grip follows the pointer's delta
    /// from `from` (an off-centre press doesn't jump) and snaps only along the
    /// screen axes it can move; `.rotate`, `.bend`, and `.tangent` are unsnapped.
    /// `stretch` (⇧) frees an image kind from its aspect ratio. Returns the
    /// result and the guides it reached.
    public func dragging(_ handle: SelectionHandle, from: CGPoint, to: CGPoint, stretch: Bool = false,
                         minExtent: CGFloat, rotateOffset: CGFloat,
                         targets: [SnapTarget], range: CGFloat, skip: Bool)
        -> (annotation: Annotation, guides: [SnapGuide]) {
        switch handle {
        case .rotate, .bend, .tangent:
            return (dragging(handle, from: from, to: to, stretch: stretch), [])
        default: break
        }
        // the grip may be a point grip or a bounding-box one, whichever set the press took
        guard let grip = (handles(.points, minExtent: minExtent, rotateOffset: rotateOffset)
                          + handles(.frame, minExtent: minExtent, rotateOffset: rotateOffset))
            .filter({ $0.handle == handle })
            .min(by: { hypot($0.at.x - from.x, $0.at.y - from.y) < hypot($1.at.x - from.x, $1.at.y - from.y) })?.at
        else { return (dragging(handle, from: from, to: to, stretch: stretch), []) }
        let proposed = CGPoint(x: grip.x + to.x - from.x, y: grip.y + to.y - from.y)
        let r = SnappingEngine.snap(points: [proposed], targets: targets,
                                    range: range, skip: skip, axes: freeAxes(handle))
        // delta-based handles (vertex) read `from` for the grip's position, so
        // forward the grip — the press point would apply the press offset twice
        return (dragging(handle, from: grip,
                         to: CGPoint(x: proposed.x + r.offset.x, y: proposed.y + r.offset.y),
                         stretch: stretch),
                r.guides)
    }

    /// the screen axes a grip can move along: corners both; a side grip moves
    /// along its one local axis, which maps to a screen axis only at
    /// right-angle rotations — flips don't change axes
    private func freeAxes(_ handle: SelectionHandle) -> SnapAxes {
        if case .vertex = handle { return .both } // an end moves anywhere
        let x: Int, y: Int
        switch handle {
        case let .resize(hx, hy), let .source(hx, hy): (x, y) = (hx, hy)
        default: return []
        }
        let local: SnapAxes
        switch (x != 0, y != 0) {
        case (true, true): return .both
        case (false, true): local = .y
        case (true, false): local = .x
        case (false, false): return []
        }
        let q = transform.rotation / (.pi / 2)
        guard abs(q - q.rounded()) < 1e-6 else { return [] }
        let odd = ((Int(q.rounded()) % 2) + 2) % 2 == 1
        return odd ? (local == .x ? .y : .x) : local
    }
}
