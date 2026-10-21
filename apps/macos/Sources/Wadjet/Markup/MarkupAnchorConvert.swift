import AppKit
import WadjetKit

/// ⌥ on an anchor under the Draw Tool or Direct Select, after Illustrator's
/// Anchor Point tool: a click converts it between smooth and corner, a drag
/// pulls out new smooth handles. The geometry lives in WadjetKit's
/// AnchorConvert.swift; the press's gesture snapshot makes it one undo step.
extension MarkupController {
    /// how far, in on-screen points, a ⌥-press may wander and still click
    static let convertClickSlop: CGFloat = 3

    /// a ⌥-press on anchor `i` of `a` starts the convert gesture; false
    /// when ⌥ isn't held or the anchor has nothing to convert (a Line's end),
    /// so the press keeps its usual grip
    func beginConvertingAnchor(_ i: Int, of a: Annotation, at p: CGPoint) -> Bool {
        guard NSEvent.modifierFlags.contains(.option),
              a.convertingAnchor(i) != nil || a.pullingHandles(i, to: p) != nil else { return false }
        gesture = .convertAnchor(i, a, from: p, pulled: false)
        return true
    }

    /// a ⌥-drag past the click slop pulls symmetric handles to the pointer;
    /// Shift holds them at 45°
    func dragConvertingAnchor(to p: CGPoint, constrained: Bool) {
        guard case let .convertAnchor(i, start, from, pulled) = gesture else { return }
        guard pulled || hypot(p.x - from.x, p.y - from.y) > Self.convertClickSlop / zoom else { return }
        gesture = .convertAnchor(i, start, from: from, pulled: true)
        // an Annotation attached whole stays attached where the edit leaves it
        if let pulledOut = start.pullingHandles(i, to: p, constrained: constrained) {
            mutateUnrecorded { $0.replaceRebasing(pulledOut) }
        }
    }

    /// the release: a ⌥-click that never pulled converts the anchor
    func endConvertingAnchor() {
        guard case let .convertAnchor(i, start, _, pulled) = gesture else { return }
        if !pulled, let converted = start.convertingAnchor(i) {
            mutateUnrecorded { $0.replaceRebasing(converted) }
            AppLog.line("markup: converted an anchor")
        }
    }
}
