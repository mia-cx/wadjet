import CoreGraphics
import Foundation

/// The Draw Tool's grips on the Line or path it selects, after Illustrator's
/// Pen with a path selected: every anchor shows and drags, beside the
/// placing Tool's bounding box, a Line's bend grip, and a bend grip on each
/// segment of a path (SegmentBend.swift).
extension Annotation {
    /// one `.vertex` grip per anchor, on screen: a Line's two ends, every
    /// node of a path — the ones the Draw Tool inserted included, and a Brush
    /// stroke's fitted nodes (never its raw samples). Empty for other kinds.
    public var anchorGrips: [(handle: SelectionHandle, at: CGPoint)] {
        let m = affineTransform
        switch kind {
        case let .line(start, end, _):
            return [(.vertex(0), start.applying(m)), (.vertex(1), end.applying(m))]
        case let .path(data):
            return data.nodes.indices.map { (.vertex($0), data.nodes[$0].anchor.applying(m)) }
        default:
            return []
        }
    }

    /// where `handle` sits on screen, nearest `press` when it shows twice —
    /// from whichever set the press took: point grips, the frame, or the Draw
    /// Tool's anchors (a fresh Brush stroke's only show there)
    public func gripPosition(_ handle: SelectionHandle, near press: CGPoint,
                             minExtent: CGFloat, rotateOffset: CGFloat) -> CGPoint? {
        (handles(.points, minExtent: minExtent, rotateOffset: rotateOffset)
            + handles(.frame, minExtent: minExtent, rotateOffset: rotateOffset)
            + anchorGrips + segmentBendGrips(spacing: 0))
            .filter { $0.handle == handle }
            .min { hypot($0.at.x - press.x, $0.at.y - press.y) < hypot($1.at.x - press.x, $1.at.y - press.y) }?.at
    }

    /// the curve handles the Draw Tool shows around its active anchor
    /// `active`, after Illustrator: the anchor's own two, and the handle at
    /// the far end of each segment it joins (the previous node's outgoing,
    /// the next node's incoming; a closed path wraps). A handle sitting on
    /// its anchor draws nothing and gets no grip. Empty without an active
    /// anchor, or on a Line (its curve is the bend grip).
    public func activeTangentGrips(_ active: Int?) -> [(handle: SelectionHandle, at: CGPoint)] {
        guard let i = active, case let .path(data) = kind, data.nodes.indices.contains(i) else { return [] }
        let n = data.nodes.count, m = affineTransform
        var out: [(handle: SelectionHandle, at: CGPoint)] = []
        func add(_ j: Int, outgoing: Bool) {
            let node = data.nodes[j]
            guard let h = outgoing ? node.handleOut : node.handleIn, h != node.anchor,
                  !out.contains(where: { $0.handle == .tangent(j, outgoing: outgoing) }) else { return }
            out.append((.tangent(j, outgoing: outgoing), h.applying(m)))
        }
        if i > 0 || data.closed { add((i - 1 + n) % n, outgoing: true) }
        add(i, outgoing: false)
        add(i, outgoing: true)
        if i < n - 1 || data.closed { add((i + 1) % n, outgoing: false) }
        return out
    }

    /// `.drawing`'s grips: a Line's bend, then the anchors, then the curve
    /// handles around the `active` anchor, then each path segment's bend
    /// grip at least `minExtent` from its anchors, then the frame grips not
    /// sitting on an anchor — a Line's ends are two of its frame's corners,
    /// and the anchor would win every press there anyway
    func drawingHandles(minExtent: CGFloat, rotateOffset: CGFloat,
                        active: Int? = nil) -> [(handle: SelectionHandle, at: CGPoint)] {
        let anchors = anchorGrips
        let frame = frameHandles(minExtent: minExtent, rotateOffset: rotateOffset).filter { f in
            !anchors.contains { hypot($0.at.x - f.at.x, $0.at.y - f.at.y) < 0.5 }
        }
        return handles(.placed, minExtent: minExtent, rotateOffset: rotateOffset).filter { $0.handle == .bend }
            + anchors + activeTangentGrips(active) + segmentBendGrips(spacing: minExtent) + frame
    }

    /// what a Draw Tool press on this selected Annotation grabs, in order:
    /// an anchor within `radius`, then a curve handle of the `active`
    /// anchor, then a bend grip, then the stroke within `tolerance` (a new
    /// node there), then a frame grip. nil when it reaches none of them; the
    /// body may still take the press as a move.
    public func drawPress(at p: CGPoint, radius: CGFloat, tolerance: CGFloat,
                          minExtent: CGFloat, rotateOffset: CGFloat, active: Int? = nil) -> DrawPress? {
        let grip = handle(at: p, radius: radius, minExtent: minExtent, rotateOffset: rotateOffset,
                          set: .drawing, active: active)
        if let grip, !grip.isFrame { return .grip(grip) }
        if kind.insertsNodes, let (a, i, t) = insertingNodeSplit(near: p, within: tolerance) {
            return .insert(a, node: i, t: t)
        }
        return grip.map { .grip($0) }
    }
}

/// a Draw Tool press on its selection: a grip to drag, or a node the press
/// adds to the stroke (the Annotation with it, its index, and the split's t)
public enum DrawPress: Equatable, Sendable {
    case grip(SelectionHandle)
    case insert(Annotation, node: Int, t: CGFloat)

    /// the Draw Tool's active anchor after this press, from `active` before
    /// it: a press on an anchor makes it active (it fills, its curve handles
    /// show); one on a curve handle or a bend grip keeps it; any other press
    /// (the stroke, the frame, the body, elsewhere — `nil`) clears it
    public static func activeAnchor(after press: DrawPress?, was active: Int?) -> Int? {
        switch press {
        case let .grip(.vertex(i))?: i
        case .grip(.tangent)?, .grip(.bend)?, .grip(.segmentBend)?: active
        default: nil
        }
    }
}

extension SelectionHandle {
    /// a bounding-box grip: resize or rotate. Under `.drawing` an anchor or
    /// the bend within reach wins over these, even one a hair nearer, so a
    /// node on a frame corner stays grabbable.
    var isFrame: Bool {
        switch self {
        case .resize, .rotate: true
        default: false
        }
    }

    /// the Draw Tool's press order within reach: anchors, the active
    /// anchor's curve handles, bend grips, any other point grip, the frame
    var drawingRank: Int {
        switch self {
        case .vertex: 0
        case .tangent: 1
        case .bend, .segmentBend: 2
        case .resize, .rotate: 4
        default: 3
        }
    }
}
