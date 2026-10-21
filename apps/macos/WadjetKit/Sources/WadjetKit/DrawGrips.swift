import CoreGraphics
import Foundation

/// The Draw Tool's grips on the Line or path it selects, after Illustrator's
/// Pen with a path selected: every anchor shows and drags, beside the
/// placing Tool's bounding box and a Line's bend grip.
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

    /// `.drawing`'s grips: a Line's bend, then the anchors, then the frame
    /// grips not sitting on an anchor — a Line's ends are two of its frame's
    /// corners, and the anchor would win every press there anyway
    func drawingHandles(minExtent: CGFloat, rotateOffset: CGFloat) -> [(handle: SelectionHandle, at: CGPoint)] {
        let anchors = anchorGrips
        let frame = frameHandles(minExtent: minExtent, rotateOffset: rotateOffset).filter { f in
            !anchors.contains { hypot($0.at.x - f.at.x, $0.at.y - f.at.y) < 0.5 }
        }
        return handles(.placed, minExtent: minExtent, rotateOffset: rotateOffset).filter { $0.handle == .bend }
            + anchors + frame
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
}
